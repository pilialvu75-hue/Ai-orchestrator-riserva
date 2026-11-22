#!/usr/bin/env python3
"""Geometry/export verification and local-only receipts. Never claim Fusion/print PASS."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile
from xml.etree import ElementTree as ET

import cadquery as cq
from OCP.BRepAdaptor import BRepAdaptor_Surface
import trimesh

from parametric_plate import make_part, read_parameters, expected_volume


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def check_brep(part, spec):
    length, width, thickness, holes = read_parameters(spec)
    shape = part.val()
    if not shape.isValid():
        raise ValueError("Invalid BREP")
    bbox = shape.BoundingBox()
    observed = [bbox.xmin, bbox.ymin, bbox.zmin, bbox.xmax, bbox.ymax, bbox.zmax]
    target = [0, 0, 0, length, width, thickness]
    if any(abs(a-b) > 1e-5 for a, b in zip(observed, target)):
        raise ValueError("BREP bounds mismatch")
    if abs(shape.Volume() - expected_volume(spec)) > 1e-4:
        raise ValueError("BREP volume mismatch")
    cylinders = []
    for face in shape.Faces():
        if face.geomType() == "CYLINDER":
            surface = BRepAdaptor_Surface(face.wrapped).Cylinder()
            center = surface.Location()
            cylinders.append((center.X(), center.Y(), surface.Radius() * 2))
    if len(cylinders) != len(holes) or any(
        max(abs(a-b) for a, b in zip(c, h)) > 1e-5
        for c, h in zip(sorted(cylinders), sorted(holes))
    ):
        raise ValueError("Expected through-holes missing/misaligned")
    return {"bboxMm": target, "holes": [list(c) for c in cylinders],
            "volumeMm3": shape.Volume(), "topologyValid": True}



def check_mesh_hole_sections(mesh, spec):
    """Verify bore center/radius at three heights, not only mesh volume/bounds.

    CAD-1 requires a rectangular plate and exactly two cylindrical through
    holes. A moved bore can retain exactly the same volume and bounding box.
    Cross sections also reject blind bores, extra contours and displaced rims.
    """
    import math
    import numpy as np

    length, width, thickness, holes = read_parameters(spec)
    expected = sorted((x, y, diameter / 2) for x, y, diameter in holes)
    verified = []
    for fraction in (0.1, 0.5, 0.9):
        z = thickness * fraction
        section = mesh.section(
            plane_origin=(0, 0, z), plane_normal=(0, 0, 1)
        )
        if section is None:
            raise ValueError("Missing mesh cross-section")
        loops = []
        for contour in section.discrete:
            pts = np.asarray(contour, dtype=float)
            if (
                len(pts) < 4
                or not np.all(np.isfinite(pts))
                or np.linalg.norm(pts[0] - pts[-1]) > 0.03
            ):
                raise ValueError("Open or malformed mesh contour")
            x, y = pts[:, 0], pts[:, 1]
            cross = x[:-1] * y[1:] - x[1:] * y[:-1]
            area = float(np.sum(cross) / 2)
            if abs(area) <= 1e-8:
                raise ValueError("Degenerate mesh contour")
            center = (
                float(np.sum((x[:-1] + x[1:]) * cross) / (6 * area)),
                float(np.sum((y[:-1] + y[1:]) * cross) / (6 * area)),
            )
            loops.append((abs(area), center, pts))
        if len(loops) != 3:
            raise ValueError(
                f"Expected exterior and 2 bore contours; found {len(loops)}"
            )
        loops.sort(key=lambda entry: entry[0], reverse=True)
        exterior = loops[0]
        if abs(exterior[0] - length * width) > max(
            0.06, length * width * 0.0005
        ):
            raise ValueError("Mesh exterior is not the measured rectangle")
        boundary = exterior[2][:, :2]
        distances = np.minimum.reduce(
            (
                abs(boundary[:, 0]),
                abs(boundary[:, 0] - length),
                abs(boundary[:, 1]),
                abs(boundary[:, 1] - width),
            )
        )
        if float(np.max(distances)) > 0.035:
            raise ValueError("Mesh exterior contour departs from rectangle")
        actual_holes = sorted(
            loops[1:], key=lambda entry: (entry[1][0], entry[1][1])
        )
        centers = []
        for (area, (cx, cy), points), (hx, hy, radius) in zip(
            actual_holes, expected
        ):
            if math.hypot(cx - hx, cy - hy) > 0.035:
                raise ValueError("Mesh bore center differs from CadSpec")
            if abs(area - math.pi * radius**2) > max(
                0.04, math.pi * radius**2 * 0.004
            ):
                raise ValueError("Mesh bore area differs from diameter")
            radial = np.hypot(
                points[:-1, 0] - hx, points[:-1, 1] - hy
            )
            if float(np.max(abs(radial - radius))) > max(
                0.035, radius * 0.012
            ):
                raise ValueError("Mesh bore contour differs from circle")
            centers.append([cx, cy])
        verified.append({"zMm": z, "boreCentersMm": centers})
    return verified


def check_mesh(path, spec):
    length, width, thickness, _ = read_parameters(spec)
    mesh = trimesh.load(str(path), force="mesh")
    if not (isinstance(mesh, trimesh.Trimesh) and mesh.is_watertight
            and mesh.is_winding_consistent and mesh.is_volume):
        raise ValueError("Mesh is not a positive closed volume")
    if any(abs(a-b) > 0.03 for a, b in zip(mesh.extents, (length, width, thickness))):
        raise ValueError("Mesh bounding box mismatch")
    error = abs(mesh.volume - expected_volume(spec)) / expected_volume(spec)
    if error >= .002:
        raise ValueError("Mesh volume relative error exceeds 0.2%")
    sections = check_mesh_hole_sections(mesh, spec)
    return {"watertight": True, "volumeMm3": float(mesh.volume),
            "relativeVolumeError": float(error), "triangles": int(len(mesh.faces)),
            "holeSections": sections}


def check_3mf_units(path):
    with zipfile.ZipFile(path) as z:
        model_files = [name for name in z.namelist() if name.endswith(".model")]
        if "[Content_Types].xml" not in z.namelist() or not model_files:
            raise ValueError("Missing 3MF package parts")
        for name in model_files:
            if ET.fromstring(z.read(name)).attrib.get("unit") != "millimeter":
                raise ValueError("3MF units are not mm")
    return {"units": "millimeter", "modelParts": model_files}


def validate(spec_path, exports_path, receipt_path):
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    exports_path = Path(exports_path)
    checks = []
    def capture(name, fn):
        try:
            checks.append({"check": name, "result": "PASS", "evidence": fn()})
        except Exception as ex:
            checks.append({"check": name, "result": "FAIL", "error": str(ex)})
    capture("source_brep", lambda: check_brep(make_part(spec), spec))
    capture("step_round_trip", lambda: check_brep(
        cq.importers.importStep(str(exports_path / "plate.step")), spec))
    capture("stl_mesh", lambda: check_mesh(exports_path / "plate.stl", spec))
    capture("3mf_units", lambda: check_3mf_units(exports_path / "plate.3mf"))
    capture("3mf_mesh", lambda: check_mesh(exports_path / "plate.3mf", spec))
    # Fail closed: a failed round-trip, mesh or unit check must never publish
    # a seemingly valid output manifest. Diagnostics may retain the failure.
    all_valid = all(check["result"] == "PASS" for check in checks)
    artifacts = []
    roles = {"STEP": ("step", "cad", "brep", "model/step"),
             "STL": ("stl", "mesh", "mesh", "model/stl"),
             "3MF": ("3mf", "mesh", "mesh", "model/3mf")}
    for fmt, (ext, role, geo, mime) in roles.items():
        path = exports_path / ("plate." + ext)
        if all_valid and path.is_file():
            artifacts.append({"name": path.name, "role": role, "format": fmt,
                              "mimeType": mime, "sizeBytes": path.stat().st_size,
                              "sha256": digest(path),
                              "sourceSpecRevision": spec["specRevision"],
                              "geometryType": geo, "units": "mm",
                              "generator": {"name": "CadQuery", "version": cq.__version__,
                                            "jobRef": "LOCAL_ONLY_NO_CLAIM_RECEIPT"}})
    for name in ("fusion_target_open", "physical_print", "cantiere_runner", "remote_diagnostics"):
        checks.append({"check": name, "result": "UNKNOWN", "reason": "Not executed here"})
    result = {"receiptType": "CAD1_LOCAL_GEOMETRY_ONLY",
              "status": "PASS" if all_valid else "FAIL",
              "notCanonicalEvidence": True, "specRevision": spec["specRevision"],
              "inputSha256": digest(spec_path), "artifacts": artifacts,
              "checks": checks, "runtimeIntegration": "NOT_IMPLEMENTED"}
    Path(receipt_path).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument("project_extension", type=Path)
    p.add_argument("--exports", required=True, type=Path)
    p.add_argument("--report", required=True, type=Path)
    args = p.parse_args()
    result = validate(args.project_extension, args.exports, args.report)
    for c in result["checks"]:
        print(c["result"], c["check"])
    if any(c["result"] == "FAIL" for c in result["checks"]):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
