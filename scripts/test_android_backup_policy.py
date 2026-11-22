"""Static security invariants for Android secure-preferences backup policy.

Issue #849. Source-only tests: no evidence of physical restore, cloud policy
execution or credential migration is implied by a pass.
"""
from __future__ import annotations

import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android" / "app" / "src" / "main"
RES_XML = ANDROID / "res" / "xml"
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"

# Verified against pinned flutter_secure_storage 10.3.4 and 11.2.0 sources.
PINNED_DEFAULT_FILES = frozenset({
    "FlutterSecureStorage.xml",
    "FlutterSecureKeyStorage.xml",
    "FlutterSecureStorageConfiguration.xml",
    "FlutterSecureStorageConfiguration:FlutterSecureStorage.xml",
})


def entries(root: ET.Element) -> set[tuple[str | None, str | None]]:
    return {
        (entry.attrib.get("domain"), entry.attrib.get("path"))
        for entry in root.findall("exclude")
    }


class AndroidSecretBackupPolicyTest(unittest.TestCase):
    def test_main_manifest_refs_both_policies(self) -> None:
        root = ET.parse(ANDROID / "AndroidManifest.xml").getroot()
        app = root.find("application")
        self.assertIsNotNone(app)
        self.assertEqual(
            app.attrib.get(ANDROID_NS + "fullBackupContent"), "@xml/backup_rules"
        )
        self.assertEqual(
            app.attrib.get(ANDROID_NS + "dataExtractionRules"),
            "@xml/data_extraction_rules",
        )
        # Preserve ordinary backup data; do not globally disable backups.
        self.assertNotIn(ANDROID_NS + "allowBackup", app.attrib)
        self.assertEqual(
            app.attrib.get(ANDROID_NS + "name"), "${applicationName}"
        )

    def test_legacy_policy_excludes_only_default_secure_stores(self) -> None:
        root = ET.parse(RES_XML / "backup_rules.xml").getroot()
        self.assertEqual(root.tag, "full-backup-content")
        self.assertEqual(
            entries(root),
            {("sharedpref", name) for name in PINNED_DEFAULT_FILES},
        )
        self.assertEqual(len(root.findall("exclude")), len(PINNED_DEFAULT_FILES))
        self.assertEqual(root.findall("include"), [])

    def test_android12_cloud_and_device_transfer_equivalent_exclusions(self) -> None:
        root = ET.parse(RES_XML / "data_extraction_rules.xml").getroot()
        self.assertEqual(root.tag, "data-extraction-rules")
        self.assertEqual(
            [entry.tag for entry in root],
            ["cloud-backup", "device-transfer"],
        )
        expected = {("sharedpref", name) for name in PINNED_DEFAULT_FILES}
        for channel in ("cloud-backup", "device-transfer"):
            with self.subTest(channel=channel):
                group = root.find(channel)
                self.assertIsNotNone(group)
                self.assertEqual(entries(group), expected)
                self.assertEqual(
                    len(group.findall("exclude")), len(PINNED_DEFAULT_FILES)
                )
                self.assertEqual(group.findall("include"), [])

    def test_no_broad_exclusions_of_unrelated_preferences(self) -> None:
        for policy in ("backup_rules.xml", "data_extraction_rules.xml"):
            with self.subTest(policy=policy):
                root = ET.parse(RES_XML / policy).getroot()
                for entry in root.iter("exclude"):
                    self.assertEqual(entry.attrib["domain"], "sharedpref")
                    self.assertIn(entry.attrib["path"], PINNED_DEFAULT_FILES)
                    self.assertNotIn(entry.attrib["path"], {".", "/", "*"})
                for entry in root.iter("include"):
                    self.fail("Unexpected include narrows unrelated app backups")


if __name__ == "__main__":
    unittest.main()
