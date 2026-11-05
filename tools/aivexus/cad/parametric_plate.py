#!/usr/bin/env python3
"""CAD-1 measured sample generator. Domain-only, no Cantiere runner or credentials."""
import argparse
import json
import math
from pathlib import Path

import cadquery as cq


def read_parameters(extension):
    if extension.get("schemaVersion") != 1 or extension.get("projectKind") != "cad":
        raise ValueError("Expected Aivexus CAD ProjectExtension v1")
    spec = extension["domainSpec"]
    if spec.get("inputMode") != "description" or spec.get("representation") != "parametric_solid":
        raise ValueError("Only measured parametric description input is supported")
    if spec.get("units") != "mm":
        raise ValueError("CAD-1 explicitly requires mm units")
    revision = extension.get("specRevision")
    if type(revision) is not int or revision < 1:
        raise ValueError("Invalid specRevision")
    p = spec["parameters"]
    length, width, thickness = (float(p[k]) for k in ("lengthMm", "widthMm", "thicknessMm"))
    if not all(math.isfinite(v) and v > 0 for v in (length, width, thickness)):
        raise ValueError("Dimensions must be positive and finite")
    holes = [(float(h["centerXMm"]), float(h["centerYMm"]), float(h["diameterMm"])) for h in p["holes"]]
    if len(holes) != 2:
        raise ValueError("The CAD-1 sample requires exactly two holes")
    for x, y, diameter in holes:
        if not all(math.isfinite(v) for v in (x, y, diameter)) or diameter <= 0:
            raise ValueError("Invalid hole")
        if not (diameter / 2 < x < length - diameter / 2
                and diameter / 2 < y < width - diameter / 2):
            raise ValueError("Hole crosses the boundary")
    (x0, y0, d0), (x1, y1, d1) = holes
    if math.hypot(x1 - x0, y1 - y0) <= (d0 + d1) / 2:
        raise ValueError("Holes overlap")
    return length, width, thickness, holes


def make_part(extension):
    length, width, thickness, holes = read_parameters(extension)
    plate = cq.Workplane("XY").box(length, width, thickness, centered=(False, False, False))
    for x, y, diameter in holes:
        bore = cq.Workplane("XY").center(x, y).circle(diameter / 2).extrude(thickness)
        plate = plate.cut(bore)
    if not plate.val().isValid():
        raise ValueError("Invalid BREP")
    return plate


def expected_volume(extension):
    length, width, thickness, holes = read_parameters(extension)
    return thickness * (length * width - sum(math.pi * (d / 2) ** 2 for _, _, d in holes))


def export_part(part, output_dir):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    result = {}
    for fmt, extension in (("STEP", "step"), ("STL", "stl"), ("3MF", "3mf")):
        target = output_dir / ("plate." + extension)
        cq.exporters.export(part, str(target), exportType=fmt,
                            tolerance=0.02, angularTolerance=0.05, unit="MM")
        result[fmt] = target
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("project_extension", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    spec = json.loads(args.project_extension.read_text(encoding="utf-8"))
    part = make_part(spec)
    generated = export_part(part, args.out)
    print(json.dumps({"specRevision": spec["specRevision"],
                      "volumeMm3": part.val().Volume(),
                      "outputs": {fmt: str(path) for fmt, path in generated.items()}}, indent=2))


if __name__ == "__main__":
    main()
