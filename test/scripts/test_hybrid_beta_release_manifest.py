import tempfile
import unittest
from pathlib import Path
from scripts.hybrid_beta_release_manifest import make, resolve


class HybridBetaReleaseManifestTests(unittest.TestCase):
    sha = "a" * 40
    run_number = "42111000001"

    def test_explicit_beta_roundtrip(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "manifest.txt"
            target.write_text(
                make(self.sha, self.run_number, "v1.0.15-beta+100123", "beta", "true"),
                encoding="utf-8",
            )
            self.assertEqual(
                resolve(target, self.sha, self.run_number, "v1.0.15-beta+100123"),
                "true",
            )

    def test_ordinary_beta_remains_off(self):
        self.assertIn("enabled=false", make(
            self.sha, self.run_number, "v1.0.15-beta+100123", "beta", "false"
        ))

    def test_stable_must_not_enable_hybrid(self):
        with self.assertRaises(ValueError):
            make(self.sha, self.run_number, "v1.0.15+100123", "stable", "true")

    def test_ci_and_nightly_must_not_enable_hybrid(self):
        for channel, tag in (
            ("ci", "v1.0.15+100123"),
            ("nightly", "v1.0.15-nightly+100123"),
            ("dev", "v1.0.15-dev+100123"),
        ):
            with self.subTest(channel=channel), self.assertRaises(ValueError):
                make(self.sha, self.run_number, tag, channel, "true")

    def test_wrong_authorized_commit_or_tag_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "manifest.txt"
            target.write_text(
                make(self.sha, self.run_number, "v1.0.15-beta+100123", "beta", "true"),
                encoding="utf-8",
            )
            for sha, number, tag in (
                ("b" * 40, self.run_number, "v1.0.15-beta+100123"),
                (self.sha, "42111000002", "v1.0.15-beta+100123"),
                (self.sha, self.run_number, "v1.0.15+100123"),
            ):
                with self.assertRaises(ValueError):
                    resolve(target, sha, number, tag)

    def test_missing_or_tampered_manifest_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "manifest.txt"
            with self.assertRaises(ValueError):
                resolve(target, self.sha, self.run_number, "v1.0.15-beta+100123")
            valid = make(
                self.sha, self.run_number, "v1.0.15-beta+100123", "beta", "true"
            )
            for invalid in (
                valid + "enabled=true\n",
                valid.replace("enabled=true", "enabled=yes"),
                valid.replace("channel=beta", "channel=stable"),
                valid.replace("format=", "bogus="),
            ):
                target.write_text(invalid, encoding="utf-8")
                with self.assertRaises(ValueError):
                    resolve(target, self.sha, self.run_number, "v1.0.15-beta+100123")


if __name__ == "__main__":
    unittest.main()
