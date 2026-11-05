"""Static security invariants for Android secure-preferences backup policy.

Issue #849. Source-only tests: no evidence of physical restore, cloud policy
execution or credential migration is implied by a pass.
"""
from __future__ import annotations

import unittest
import re
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


# Fail closed if a dependency update silently changes the audited native
# SharedPreferences filenames. Update only with a fresh source inventory.
REVIEWED_VERSION = "10.3.4"
REVIEWED_CONSTRAINT = "^10.3.1"
REVIEWED_DIGEST = "fe638107c5f69119156ada2db5a57734385fac3f64430bd7252a00d3ead2ca4b"


def check_secure_storage_resolution(pubspec: str, lock: str) -> None:
    constraints = re.findall(r"(?m)^  flutter_secure_storage:\s*([^\s#]+)\s*$", pubspec)
    if constraints != [REVIEWED_CONSTRAINT]:
        raise ValueError("Secure Storage dependency declaration changed")

    blocks = re.findall(
        r"(?ms)^  flutter_secure_storage:\s*\n(.*?)(?=^  [A-Za-z0-9_]+:|\Z)",
        lock,
    )
    if len(blocks) != 1:
        raise ValueError("Secure Storage lockfile entry missing or duplicated")
    block = blocks[0]
    required_lines = {
        '    dependency: "direct main"',
        "    description:",
        "      name: flutter_secure_storage",
        f"      sha256: {REVIEWED_DIGEST}",
        '      url: "https://pub.dev"',
        "    source: hosted",
        f'    version: "{REVIEWED_VERSION}"',
    }
    actual_lines = [line for line in block.splitlines() if line.strip()]
    if set(actual_lines) != required_lines or len(actual_lines) != len(required_lines):
        raise ValueError("Secure Storage version or provenance changed")


def entries(root: ET.Element) -> set[tuple[str | None, str | None]]:
    return {
        (entry.attrib.get("domain"), entry.attrib.get("path"))
        for entry in root.findall("exclude")
    }


class AndroidSecretBackupPolicyTest(unittest.TestCase):
    def test_all_android_secret_clients_preserve_on_error(self) -> None:
        # Check policy wiring at all known secret clients; device restore
        # behavior still needs Android G5 acceptance.
        clients = (
            "lib/core/runtime/inference/cloud_credential_store.dart",
            "lib/app_factory/workshop/workshop_library_github_auth.dart",
            "lib/features/module_library/data/module_library_github_config.dart",
            "lib/core/diagnostics/github_diagnostics.dart",
        )
        for filename in clients:
            with self.subTest(client=filename):
                text = (ROOT / filename).read_text(encoding="utf-8")
                self.assertIn("AndroidOptions(resetOnError: false)", text)
                self.assertNotIn("const FlutterSecureStorage()", text)

    def test_secure_storage_resolved_package_is_reviewed(self) -> None:
        check_secure_storage_resolution(
            (ROOT / "pubspec.yaml").read_text(encoding="utf-8"),
            (ROOT / "pubspec.lock").read_text(encoding="utf-8"),
        )

    def test_secure_storage_lock_guard_rejects_dependency_drift(self) -> None:
        pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
        lock = (ROOT / "pubspec.lock").read_text(encoding="utf-8")
        start = lock.index("  flutter_secure_storage:\n")
        end = lock.index("  flutter_secure_storage_darwin:\n", start)
        entry = lock[start:end]
        bad_entries = [
            entry.replace('version: "10.3.4"', 'version: "11.2.0"'),
            entry.replace("source: hosted", "source: git"),
            entry.replace('url: "https://pub.dev"', 'url: "https://unknown.example"'),
            entry.replace(REVIEWED_DIGEST, "0" * 64),
            entry + "    version: \"10.3.4\"\n",
            entry.replace('name: flutter_secure_storage', 'name: fake_storage'),
            entry.replace('dependency: "direct main"', 'dependency: transitive'),
            entry.replace("  flutter_secure_storage:\n", "  fake_storage:\n"),
        ]
        with self.assertRaises(ValueError):
            check_secure_storage_resolution(
                pubspec.replace(REVIEWED_CONSTRAINT, "^11.2.0"), lock
            )
        with self.assertRaises(ValueError):
            check_secure_storage_resolution(
                pubspec, lock[:end] + entry + lock[end:]
            )
        for candidate in bad_entries:
            with self.subTest(index=bad_entries.index(candidate)):
                with self.assertRaises(ValueError):
                    check_secure_storage_resolution(
                        pubspec, lock[:start] + candidate + lock[end:]
                    )

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
