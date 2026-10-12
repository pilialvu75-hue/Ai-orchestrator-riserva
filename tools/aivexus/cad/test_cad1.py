"""CAD-1 domain tests, including real STEP/STL/3MF round-trips.

Requires the isolated local CadQuery/OCP/trimesh toolchain; these tests do
not imply that a production Cantiere runner is already integrated.
"""
import copy
import hashlib
import json
import math
from pathlib import Path
import tempfile
import unittest

import cadquery as cq

from parametric_plate import export_part, make_part, read_parameters, expected_volume
from validate_plate import check_brep, check_mesh, check_3mf_units

EXAMPLE = json.loads(
    (Path(__file__).parent / "fixtures" / "plate_spec.json").read_text(
        encoding="utf-8"
    )
)


class Cad1Tests(unittest.TestCase):
    def test_measured_sample(self):
        obj = make_part(EXAMPLE).val()
        bb = obj.BoundingBox()
        self.assertTrue(obj.isValid())
        self.assertEqual(
            [bb.xmin, bb.ymin, bb.zmin, bb.xmax, bb.ymax, bb.zmax],
            [0, 0, 0, 60, 40, 4],
        )
        self.assertAlmostEqual(obj.Volume(), 9600 - 50 * math.pi, places=4)

    def test_revision_changes_geometry(self):
        changed = copy.deepcopy(EXAMPLE)
        changed["specRevision"] = 2
        changed["domainSpec"]["parameters"]["thicknessMm"] = 5
        self.assertAlmostEqual(
            make_part(changed).val().Volume(), expected_volume(changed)
        )
        self.assertNotEqual(
            make_part(EXAMPLE).val().Volume(), make_part(changed).val().Volume()
        )

    def test_outside_bore_rejected(self):
        bad = copy.deepcopy(EXAMPLE)
        bad["domainSpec"]["parameters"]["holes"][0]["centerXMm"] = 1
        with self.assertRaises(ValueError):
            read_parameters(bad)

    def test_overlapping_bores_rejected(self):
        bad = copy.deepcopy(EXAMPLE)
        bad["domainSpec"]["parameters"]["holes"][1]["centerXMm"] = 16
        with self.assertRaises(ValueError):
            read_parameters(bad)

    def test_incorrect_units_rejected(self):
        bad = copy.deepcopy(EXAMPLE)
        bad["domainSpec"]["units"] = "inch"
        with self.assertRaises(ValueError):
            read_parameters(bad)

    def test_incorrect_revision_rejected(self):
        bad = copy.deepcopy(EXAMPLE)
        bad["specRevision"] = 0
        with self.assertRaises(ValueError):
            read_parameters(bad)

    def _verify_real_exports(self, revision):
        spec = copy.deepcopy(EXAMPLE)
        spec["specRevision"] = revision
        spec["domainSpec"]["parameters"]["thicknessMm"] = (
            4 if revision == 1 else 5
        )
        with tempfile.TemporaryDirectory() as tmp:
            paths = export_part(make_part(spec), Path(tmp))
            self.assertEqual(set(paths), {"STEP", "STL", "3MF"})
            for path in paths.values():
                self.assertTrue(path.is_file())
                self.assertGreater(path.stat().st_size, 100)
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                self.assertEqual(len(digest), 64)
            check_brep(cq.importers.importStep(str(paths["STEP"])), spec)
            check_mesh(paths["STL"], spec)
            check_3mf_units(paths["3MF"])
            check_mesh(paths["3MF"], spec)

    def test_real_exports_revision_1(self):
        self._verify_real_exports(1)

    def test_real_exports_revision_2(self):
        self._verify_real_exports(2)

    def test_corrupted_mesh_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = export_part(make_part(EXAMPLE), Path(tmp))
            paths["STL"].write_bytes(b"corrupted mesh payload")
            with self.assertRaises(Exception):
                check_mesh(paths["STL"], EXAMPLE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
