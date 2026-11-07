"""Tests for the Cantiere-to-Library executable async sandbox entry point."""
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "tool/cantiere_async_adapter_sandbox.py"

class CantiereAsyncProbeTests(unittest.TestCase):
    def test_help(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--help"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--library-sha", result.stdout)
        self.assertIn("--upstream-sha", result.stdout)

    def test_rejects_unpinned_source_without_network(self):
        result = subprocess.run([sys.executable, str(SCRIPT),
                                 "--library-sha", "main",
                                 "--upstream-sha", "a" * 40],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("full pinned", result.stderr)

    def test_rejects_unpinned_library_without_network(self):
        result = subprocess.run([sys.executable, str(SCRIPT),
                                 "--library-sha", "a" * 40,
                                 "--upstream-sha", "main"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("full pinned", result.stderr)

if __name__ == "__main__":
    unittest.main()
