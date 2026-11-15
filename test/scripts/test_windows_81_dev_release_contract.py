"""Fail-closed contract for the owner-only Windows 8.1 release workflow."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/windows-81-dev-update.yml"
INNO = ROOT / "windows/installer/ai_orchestrator.iss"

class Windows81ReleaseContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.inno = INNO.read_text(encoding="utf-8")

    def test_owner_only_publish(self):
        w = self.workflow
        for required in [
            "workflow_dispatch:", "github.ref == 'refs/heads/main'",
            "github.actor == 'pilialvu75-hue'", "default: build_only",
            "publish_win81_dev", "PUBLISH_WIN81_RECOVERY_DEV",
            "if: inputs.action == 'publish_win81_dev'",
            "gh release create", "--draft", "--draft=false",
        ]:
            self.assertIn(required, w)
        for forbidden in ["\n  push:", "\n  workflow_run:", "--clobber"]:
            self.assertNotIn(forbidden, w)

    def test_backup_local_inference_sha_and_exclusive_win81(self):
        w = self.workflow
        for required in [
            "tool\\windows_rollback\\test_recovery.ps1",
            "Compile mandatory Windows rollback recovery helper",
            "AivexusWin81UnsignedQABuild", "AivexusRecoveryHelper",
            "tool\\test_windows_llama_bundle.ps1",
            "tool\\patch_windows_bundle_win7.ps1",
            "AI-Orchestrator-Setup-x64.exe.sha256",
            "enabled=false", "v1.0.15-dev+", "No Android update.",
            "Get-FileHash $setup -Algorithm SHA256",
            "exeAsset[0].digest",
            "gh api \"repos/$repo/releases/tags/$tag\"",
        ]:
            self.assertIn(required, w)
        self.assertIn("OnlyBelowVersion=10.0", self.inno)
        self.assertIn("A Windows 8.1 unsigned QA installation must include", self.inno)
        self.assertNotIn("Validate already authorized Android release", w)
        self.assertNotIn("Verify matching Android release exists", w)

if __name__ == "__main__":
    unittest.main()
