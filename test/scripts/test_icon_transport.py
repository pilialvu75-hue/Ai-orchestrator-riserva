"""No-network tests: icon upload transport must preserve original byte-for-byte."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import lzma
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile, ZIP_STORED

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "unpack_icon_transport.py"
spec = importlib.util.spec_from_file_location("unpack_icon_transport", SCRIPT)
assert spec and spec.loader
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


class IconTransferTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.original = self.root / transport.ORIGINAL_NAME
        with ZipFile(self.original, "w") as archive:
            for i in range(109):
                archive.writestr("AI-Orchestrator-Platform-Icons/mock_%03d.png" % i, b"PNG" + bytes([i]))
        self.original_sha = hashlib.sha256(self.original.read_bytes()).hexdigest()
        self.wrapper = self.root / transport.TRANSPORT_NAME
        inner = lzma.compress(self.original.read_bytes())
        with ZipFile(self.wrapper, "w", compression=ZIP_STORED) as out:
            out.writestr(transport.INNER_NAME, inner)
            out.writestr("README-GITHUB-TRANSFER.txt", "Original icons\n")
        self.wrapper_sha = hashlib.sha256(self.wrapper.read_bytes()).hexdigest()
        self.target = self.root / "restored.zip"

    def test_compact_wrapper_restores_identical_original(self):
        transport.unpack_icons(self.wrapper, self.target, original_sha=self.original_sha,
                               transport_sha=self.wrapper_sha)
        self.assertEqual(self.target.read_bytes(), self.original.read_bytes())

    def test_original_zip_can_still_be_used(self):
        transport.unpack_icons(self.original, self.target, original_sha=self.original_sha)
        self.assertEqual(self.target.read_bytes(), self.original.read_bytes())

    def test_corrupt_wrapper_rejected_before_writing(self):
        with self.assertRaises(ValueError):
            transport.unpack_icons(self.wrapper, self.target, original_sha=self.original_sha)
        self.assertFalse(self.target.exists())

    def test_mismatched_original_rejected(self):
        with self.assertRaises(ValueError):
            transport.unpack_icons(self.wrapper, self.target,
                                   original_sha="0" * 64, transport_sha=self.wrapper_sha)
        self.assertFalse(self.target.exists())


if __name__ == "__main__":
    unittest.main()
