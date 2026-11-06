import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from tool.cantiere_real_star_receipt_gate import validate, REQUIRED_ROLES


class StarReceiptGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.apk = Path(self.tmp.name) / "star.apk"
        self.apk.write_bytes(b"synthetic-APK-for-unit-test-only")
        self.receipt = Path(self.tmp.name) / "receipt.json"
        self.data = {
            "gate": "REAL_STAR_PRODUCTION_BUILD",
            "production_lifecycle": "existing_cantiere",
            "four_roles_replied": True,
            "artifact_built": True,
            "apk_sha256": hashlib.sha256(self.apk.read_bytes()).hexdigest(),
            "independent_model_generation_provenance_verified": False,
            "emulator_visual_verified": False,
            "geometric_star_verified": False,
            "android_local_verified": False,
            "windows_local_verified": False,
            "role_receipts": {
                role: {"successful_calls": 1, "models": ["mock-test-model"]}
                for role in REQUIRED_ROLES
            },
        }

    def check(self):
        self.receipt.write_text(json.dumps(self.data), encoding="utf-8")
        return validate(self.apk, self.receipt)

    def test_valid_synthetic_receipt(self):
        self.assertEqual(self.check(), self.data["apk_sha256"])

    def test_changed_apk_is_rejected(self):
        self.apk.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "HASH_MISMATCH"):
            self.check()

    def test_missing_role_is_rejected(self):
        del self.data["role_receipts"]["coding"]
        with self.assertRaisesRegex(ValueError, "ROLE_SET"):
            self.check()

    def test_fake_role_call_count_rejected(self):
        self.data["role_receipts"]["review"]["successful_calls"] = 0
        with self.assertRaisesRegex(ValueError, "ROLE_CALL"):
            self.check()

    def test_premature_device_success_rejected(self):
        self.data["android_local_verified"] = True
        with self.assertRaisesRegex(ValueError, "PREMATURE_SUCCESS"):
            self.check()

    def test_absent_apk_fails(self):
        self.apk.unlink()
        with self.assertRaisesRegex(ValueError, "APK_MISSING"):
            self.check()


if __name__ == "__main__":
    unittest.main()
