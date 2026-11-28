"""Static safety and packaging contract for optional Microsoft Store MSIX QA.

Source-only until owner reserves a real Store identity and Microsoft signs it.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/windows-store-msix-qa.yml").read_text("utf-8")
PACKAGER = (ROOT / "tool/build_windows_store_msix.ps1").read_text("utf-8")


class WindowsStoreMsixContractTest(unittest.TestCase):
    def test_no_public_release_or_trusted_signing_claim(self):
        self.assertIn("pull_request:", WORKFLOW)
        self.assertIn("workflow_dispatch:", WORKFLOW)
        self.assertIn("permissions:\n  contents: read", WORKFLOW)
        self.assertNotIn("gh release create", WORKFLOW)
        self.assertNotIn("gh release upload", WORKFLOW)
        self.assertNotIn("msstore publish", WORKFLOW)
        self.assertNotIn("SignTool sign", WORKFLOW)
        self.assertIn("UNSIGNED. Do NOT sideload", WORKFLOW)
        self.assertIn("compression-level: 1", WORKFLOW)

    def test_three_features_are_always_packaged_together(self):
        for define in (
            "AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA=true",
            "AIVEXUS_WINDOWS_CUDA_QA=true",
            "AIVEXUS_LOCAL_TEST_BRIDGE=true",
            "AIVEXUS_WINDOWS_STORE_MSIX=true",
        ):
            self.assertIn(define, WORKFLOW)
        self.assertIn("bundle_windows_cuda_runtime.ps1", WORKFLOW)
        self.assertIn("test_windows_cuda_bundle.ps1", WORKFLOW)
        self.assertIn("scripts\\chatgpt_bridge\\aivexus_mcp.ps1", WORKFLOW)
        self.assertIn("mcp-tools\\aivexus_mcp.ps1", PACKAGER)
        self.assertIn("runtime-cuda\\llama-server.exe", PACKAGER)
        self.assertIn("runtime-cuda\\ggml-cuda.dll", PACKAGER)

    def test_store_identity_and_version_are_explicit(self):
        self.assertIn("reserved Partner Center product name", PACKAGER)
        self.assertIn("CN=", PACKAGER)
        self.assertIn("AIVEXUS.QA", WORKFLOW)
        self.assertIn("Real Store Product identity required", WORKFLOW)
        self.assertIn('Version="$Version"', PACKAGER)
        self.assertIn('$version = "1.0.$number.0"', WORKFLOW)
        self.assertIn("must have four numeric segments and end in .0", PACKAGER)
        self.assertIn("ProcessorArchitecture=\"x64\"", PACKAGER)
        self.assertIn("runFullTrust", PACKAGER)
        self.assertIn("Windows.Desktop", PACKAGER)

    def test_microsoft_sdk_packages_and_unpacks_before_upload(self):
        self.assertIn("makeappx.exe", PACKAGER)
        self.assertIn(" pack /d $stage /p $output /o", PACKAGER)
        self.assertIn(" unpack /p $output /d $verify /o", PACKAGER)
        self.assertIn("Get-FileHash", PACKAGER)
        self.assertIn("AIVEXUS-Windows-Store-Beta-x64.msix.sha256", WORKFLOW)
        self.assertIn("Existing AIVEXUS Windows icon", PACKAGER)
        self.assertNotIn("Remove-Item -Recurse", PACKAGER)


if __name__ == "__main__":
    unittest.main()
