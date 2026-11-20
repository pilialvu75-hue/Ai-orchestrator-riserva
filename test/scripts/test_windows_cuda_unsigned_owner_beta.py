"""Owner opt-in unsigned Windows CUDA QA. Keeps original signed release path untouched."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
W = (ROOT / ".github/workflows/windows-cuda-unsigned-owner-beta.yml").read_text(encoding="utf-8")
INNO = (ROOT / "windows/installer/ai_orchestrator.iss").read_text(encoding="utf-8")
UPDATER = (ROOT / "lib/core/system/update/update_checker.dart").read_text(encoding="utf-8")


class UnsignedWindowsOwnerQa(unittest.TestCase):
    def test_owner_and_exact_sha_request_is_required(self):
        self.assertIn("github.actor == 'pilialvu75-hue'", W)
        self.assertIn("refs/heads/release-request/windows-cuda-unsigned-beta", W)
        self.assertIn("channel=windows-cuda-unsigned-beta", W)
        self.assertIn("owner_accepts_unsigned=true", W)
        self.assertIn('main_sha=$mainSha', W)
        self.assertIn("ref: ${{ steps.source.outputs.main_sha }}", W)
        self.assertNotIn("workflow_dispatch:", W)
        self.assertNotIn("secrets.AIVEXUS_WINDOWS_SIGNING", W)
        self.assertNotIn("AivexusTrustedSignedBuild 1", W)
        self.assertNotIn("windows_trusted_signing.ps1", W)

    def test_beta_stamps_updater_version_and_preserves_features(self):
        self.assertIn("$build = 220000 + [int]$env:GITHUB_RUN_NUMBER", W)
        self.assertIn("Release creation failed.", W)
        self.assertIn("gh release create $tag", W)
        self.assertIn("--target '${{ steps.source.outputs.main_sha }}'", W)
        self.assertIn("--prerelease", W)
        self.assertIn("AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA=true", W)
        self.assertIn("AIVEXUS_WINDOWS_CUDA_QA=true", W)
        self.assertIn("AIVEXUS_LOCAL_TEST_BRIDGE=true", W)
        self.assertIn("test/core/diagnostics/chatgpt_bridge/", W)
        self.assertIn("aivexus_mcp.ps1", W)
        self.assertIn("bundle_windows_cuda_runtime.ps1", W)
        self.assertIn("test_windows_cuda_bundle.ps1", W)
        self.assertIn("test_windows_llama_bundle.ps1", W)

    def test_qa_warns_is_unsigned_and_preexisting_installer_identity_is_preserved(self):
        self.assertIn("UNSIGNED owner-only QA binaries", W)
        self.assertIn("public GitHub prerelease asset", W)
        self.assertIn("SHA-256 checks integrity, NOT publisher identity", W)
        self.assertIn("Get-AuthenticodeSignature", W)
        self.assertIn("AivexusRecoveryHelper", W)
        self.assertIn("SnapshotInstalledVersion", INNO)
        self.assertIn("SignedUninstaller=no", INNO)
        self.assertIn("AppId={{4DB0E2A9-841F-4AC8-BC18-C72DBBA31E42}", INNO)
        self.assertIn("AI-Orchestrator-Setup-x64.exe.sha256", W)
        self.assertIn("requireSha256: true", UPDATER)
        self.assertNotIn("gh release upload", W)

    def test_powershell_cuda_gate_does_not_read_stale_native_exit_code(self):
        # PowerShell .ps1 invocations do not establish a new LASTEXITCODE.
        # A successful bundle was previously rejected after the last Flutter command.
        start = W.index("      - name: Bundle and audit pinned ASUS CUDA engine")
        end = W.index("      - name: Compile Windows recovery helper", start)
        block = W[start:end]
        self.assertIn("bundle_windows_cuda_runtime.ps1", block)
        self.assertIn("test_windows_cuda_bundle.ps1", block)
        self.assertIn("test_windows_llama_bundle.ps1", block)
        self.assertIn("patch_windows_bundle_win7.ps1", block)
        self.assertNotIn("if ($LASTEXITCODE -ne 0)", block)
        self.assertIn("PowerShell scripts throw on error", block)

    def test_owner_release_can_never_run_from_pull_request(self):
        self.assertIn("github.event_name == 'push'", W)
        self.assertIn("if: github.event_name == 'pull_request'", W)
        self.assertIn("permissions:\n  contents: read", W)
        self.assertIn("contents: write", W)
        self.assertIn("Validate reviewed main and release request", W)
        self.assertNotIn("persist-credentials: true", W)


if __name__ == "__main__":
    unittest.main()
