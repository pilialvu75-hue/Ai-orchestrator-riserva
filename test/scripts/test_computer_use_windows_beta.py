"""Static release safety contracts: computer-use Windows beta is NOT automatic.

These tests are intentionally stdlib-only so pull-request CI can verify the
manifest/updater integration contract without building an installer.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/windows-computer-use-beta.yml"
UPDATER = ROOT / "lib/core/system/update/update_checker.dart"
CHANNEL = ROOT / "lib/core/system/update/release_channel.dart"
INSTALLER = ROOT / "windows/installer/ai_orchestrator.iss"


class ComputerUseWindowsBetaContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.updater = UPDATER.read_text(encoding="utf-8")
        cls.channel = CHANNEL.read_text(encoding="utf-8")
        cls.installer = INSTALLER.read_text(encoding="utf-8")

    def test_owner_opt_in_and_main_release_only(self):
        w = self.workflow
        self.assertIn("workflow_dispatch:", w)
        self.assertIn("github.event_name == 'workflow_dispatch'", w)
        self.assertIn("github.ref == 'refs/heads/main'", w)
        self.assertIn("github.actor == 'pilialvu75-hue'", w)
        self.assertIn("YES_PUBLISH_WINDOWS_BETA", w)
        self.assertIn("default: NO", w)
        self.assertIn("if: github.event_name == 'pull_request'", w)
        self.assertNotIn("push:\n", w)

    def test_unique_tag_never_clobbers_existing_release(self):
        w = self.workflow
        self.assertIn('$build = 200000 + [int]$env:GITHUB_RUN_NUMBER', w)
        self.assertIn('$tag = "v$base-beta+$build"', w)
        self.assertIn("gh release view $tag", w)
        self.assertIn("refusing overwrite", w)
        self.assertIn("gh release create $tag", w)
        self.assertIn("--target $env:GITHUB_SHA", w)
        self.assertIn("--prerelease", w)
        self.assertNotIn("--clobber", w)
        self.assertNotIn("gh release upload", w)

    def test_build_is_real_aivexus_and_lab_flag_is_explicit(self):
        w = self.workflow
        self.assertIn("flutter build windows --release", w)
        self.assertIn("--dart-define=AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA=true", w)
        self.assertIn("AIVEXUS_EXPECT_COMPUTER_USE_QA_ENABLED=true", w)
        self.assertIn("flutter test", w)
        self.assertIn("test_windows_llama_bundle.ps1", w)
        self.assertIn("windows\\installer\\ai_orchestrator.iss", w)
        self.assertIn("AI-Orchestrator-Setup-x64.exe", w)
        self.assertIn("Get-FileHash $exe -Algorithm SHA256", w)
        self.assertIn("vc_redist.x64.exe", w)

    def test_windows_only_beta_is_detected_by_existing_updater(self):
        self.assertIn("_releaseChannelFromGitHubRelease", self.updater)
        self.assertIn("if (tagName.contains('beta')) return ReleaseChannel.beta", self.updater)
        self.assertIn("final windowsAsset = _extractWindowsAsset(release)", self.updater)
        self.assertIn("apkUrl: apkAsset?.url ?? ''", self.updater)
        self.assertIn("targetPlatform == UpdateTargetPlatform.android", self.updater)
        self.assertIn("requireSha256: true", self.updater)
        self.assertIn("ReleaseChannel.beta", self.channel)
        self.assertIn("OutputBaseFilename=AI-Orchestrator-Setup-x64", self.installer)
        self.assertIn("AppId={{4DB0E2A9-841F-4AC8-BC18-C72DBBA31E42}", self.installer)


if __name__ == "__main__":
    unittest.main()
