"""Regression tests for the approved icon pack installer (no image processing)."""
from __future__ import annotations

import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "install_platform_icons.py"
SPEC = importlib.util.spec_from_file_location("install_platform_icons", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
PREFIX = MODULE.PREFIX


class InstallPlatformIconsTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name) / "repo"
        self.root.mkdir()
        (self.root / "android/app/src/main/res/values").mkdir(parents=True)
        (self.root / "windows/runner/resources").mkdir(parents=True)
        (self.root / "macos/Runner/Assets.xcassets").mkdir(parents=True)
        (self.root / "web/icons").mkdir(parents=True)
        self.colors = self.root / "android/app/src/main/res/values/colors.xml"
        self.colors.write_text(
            '<resources>\n    <color name="unrelated">#ffffff</color>\n</resources>\n',
            encoding="utf-8",
        )
        self.pack = Path(self.scratch.name) / "approved.zip"
        with ZipFile(self.pack, "w") as z:
            z.writestr(PREFIX + "Android/res/mipmap-hdpi/ic_launcher.png", b"android")
            z.writestr(PREFIX + "Android/res/mipmap-anydpi-v26/ic_launcher.xml", b"<adaptive-icon/>")
            z.writestr(PREFIX + "Windows/app_icon.ico", b"windows")
            z.writestr(PREFIX + "macOS/AppIcon.appiconset/Contents.json", b'{"images":[]}')
            z.writestr(PREFIX + "Web_PWA/icons/Icon-192.png", b"web")
            z.writestr(PREFIX + "Web_PWA/favicon-32x32.png", b"web-favicon")
        self.digest = hashlib.sha256(self.pack.read_bytes()).hexdigest()

    def test_dry_run_never_writes_assets_or_color(self):
        before = self.colors.read_bytes()
        items = MODULE.install(self.pack, self.root, apply=False, expected_digest=self.digest)
        self.assertEqual(len(items), 7)  # Six assets plus Android color
        self.assertEqual(self.colors.read_bytes(), before)
        self.assertFalse((self.root / "windows/runner/resources/app_icon.ico").exists())

    def test_apply_copies_exact_assets_and_merges_colors(self):
        MODULE.install(self.pack, self.root, apply=True, expected_digest=self.digest)
        self.assertEqual(
            (self.root / "windows/runner/resources/app_icon.ico").read_bytes(), b"windows"
        )
        self.assertEqual(
            (self.root / "android/app/src/main/res/mipmap-hdpi/ic_launcher.png").read_bytes(), b"android"
        )
        self.assertIn("unrelated", self.colors.read_text(encoding="utf-8"))
        self.assertIn("ic_launcher_background", self.colors.read_text(encoding="utf-8"))
        # Re-applying must not duplicate resource definitions.
        MODULE.install(self.pack, self.root, apply=True, expected_digest=self.digest)
        self.assertEqual(
            self.colors.read_text(encoding="utf-8").count("ic_launcher_background"), 1
        )

    def test_wrong_pack_is_rejected_without_writing(self):
        with self.assertRaises(ValueError):
            MODULE.install(self.pack, self.root, apply=True, expected_digest="0" * 64)
        self.assertFalse((self.root / "windows/runner/resources/app_icon.ico").exists())


if __name__ == "__main__":
    unittest.main()
