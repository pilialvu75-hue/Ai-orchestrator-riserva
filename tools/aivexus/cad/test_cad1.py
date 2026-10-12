"""Local CAD-1 tests; require CadQuery/OCP on the isolated runner."""
import copy
import json
import math
from pathlib import Path
import unittest

from parametric_plate import make_part, read_parameters, expected_volume

EXAMPLE = json.loads((Path(__file__).parent / "fixtures" / "plate_spec.json").read_text(encoding="utf-8"))


class Cad1Tests(unittest.TestCase):
    def test_measured_sample(self):
        obj = make_part(EXAMPLE).val()
        bb = obj.BoundingBox()
        self.assertTrue(obj.isValid())
        self.assertEqual([bb.xmin, bb.ymin, bb.zmin, bb.xmax, bb.ymax, bb.zmax],
                         [0, 0, 0, 60, 40, 4])
        self.assertAlmostEqual(obj.Volume(), 9600 - 50 * math.pi, places=4)

    def test_revision_changes_geometry(self):
        changed = copy.deepcopy(EXAMPLE)
        changed["specRevision"] = 2
        changed["domainSpec"]["parameters"]["thicknessMm"] = 5
        self.assertAlmostEqual(make_part(changed).val().Volume(), expected_volume(changed))
        self.assertNotEqual(make_part(EXAMPLE).val().Volume(), make_part(changed).val().Volume())

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
