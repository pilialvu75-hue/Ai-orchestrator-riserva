"""Guard against publishing Windows packages without pre-upgrade recovery."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
NORMAL = ROOT / ".github/workflows/windows-release-publish.yml"
BETA = ROOT / ".github/workflows/windows-computer-use-beta.yml"
INNO = ROOT / "windows/installer/ai_orchestrator.iss"

class WindowsReleaseRecoveryContractTest(unittest.TestCase):
    def test_every_normal_windows_release_compiles_and_embeds_rollback(self):
        text = NORMAL.read_text(encoding="utf-8")
        compile_title = "Compile mandatory Windows rollback recovery helper"
        self.assertEqual(text.count(compile_title), 1)
        self.assertIn("tool\\windows_rollback\\AivexusRecovery.cs", text)
        self.assertIn("tool\\windows_rollback\\recovery.manifest", text)
        self.assertIn("Recovery helper failed to compile: refusing to publish", text)
        self.assertEqual(text.count('#define AivexusRecoveryHelper'), 1)
        self.assertIn("steps.recovery.outputs.helper", text)
        self.assertLess(text.index(compile_title), text.index("Prepare Windows release payload"))
        self.assertLess(text.index("Prepare Windows release payload"), text.index("Build versioned Windows Setup.exe"))
        self.assertLess(text.index("Build versioned Windows Setup.exe"), text.index("Publish Windows installer into matching GitHub Release"))

    def test_dev_1_0_16_is_restricted_to_windows_81_with_rollback(self):
        source = NORMAL.read_text(encoding="utf-8")
        inno = INNO.read_text(encoding="utf-8")
        self.assertIn("'^v1\\.0\\.16-dev\\+[0-9]+
        text = BETA.read_text(encoding="utf-8")
        self.assertIn("Require trusted code-signing identity (fail closed)", text)
        self.assertIn("AivexusTrustedSignedBuild", text)
        self.assertIn("AivexusRecoveryHelper", text)
        self.assertIn("SignedUninstaller=yes", INNO.read_text(encoding="utf-8"))

    def test_inno_aborts_before_replacing_first_program_file(self):
        text = INNO.read_text(encoding="utf-8")
        self.assertIn("CloseApplications=yes", text)
        self.assertIn("BeforeInstall: SnapshotInstalledVersion", text)
        self.assertIn("ResultCode <> 0", text)
        self.assertIn("RaiseException('Previous AIVEXUS version", text)
        first_executable = text.index('Source: "{#ReleaseDir}\\ai_orchestrator.exe"')
        backup_hook = text.index("BeforeInstall: SnapshotInstalledVersion")
        other_binaries = text.index('Source: "{#ReleaseDir}\\*"')
        self.assertLess(first_executable, backup_hook)
        self.assertLess(backup_hook, other_binaries)
        self.assertIn("Recupera versione precedente", text)
        self.assertIn("Conferma aggiornamento funzionante", text)
        self.assertIn('--roaming', text)

if __name__ == "__main__":
    unittest.main()
", source)
        self.assertIn("if ($isWin81OnlyDev)", source)
        self.assertIn("#define AivexusWin81UnsignedQABuild 1", source)
        self.assertIn("#define AivexusRecoveryHelper", source)
        self.assertIn("#error A Windows 8.1 unsigned QA installation must include", inno)
        self.assertIn("OnlyBelowVersion=10.0", inno)
        pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
        self.assertIn("version: 1.0.16+16", pubspec)

    def test_beta_windows_requires_trusted_signing(self):
        text = BETA.read_text(encoding="utf-8")
        self.assertIn("Require trusted code-signing identity (fail closed)", text)
        self.assertIn("AivexusTrustedSignedBuild", text)
        self.assertIn("AivexusRecoveryHelper", text)
        self.assertIn("SignedUninstaller=yes", INNO.read_text(encoding="utf-8"))

    def test_inno_aborts_before_replacing_first_program_file(self):
        text = INNO.read_text(encoding="utf-8")
        self.assertIn("CloseApplications=yes", text)
        self.assertIn("BeforeInstall: SnapshotInstalledVersion", text)
        self.assertIn("ResultCode <> 0", text)
        self.assertIn("RaiseException('Previous AIVEXUS version", text)
        first_executable = text.index('Source: "{#ReleaseDir}\\ai_orchestrator.exe"')
        backup_hook = text.index("BeforeInstall: SnapshotInstalledVersion")
        other_binaries = text.index('Source: "{#ReleaseDir}\\*"')
        self.assertLess(first_executable, backup_hook)
        self.assertLess(backup_hook, other_binaries)
        self.assertIn("Recupera versione precedente", text)
        self.assertIn("Conferma aggiornamento funzionante", text)
        self.assertIn('--roaming', text)

if __name__ == "__main__":
    unittest.main()
