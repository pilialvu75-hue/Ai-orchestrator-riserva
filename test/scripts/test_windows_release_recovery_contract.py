"""Contract checks for verified recovery and Windows 8.1-only QA releases."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
NORMAL = ROOT / ".github/workflows/windows-release-publish.yml"
BETA = ROOT / ".github/workflows/windows-computer-use-beta.yml"
INNO = ROOT / "windows/installer/ai_orchestrator.iss"


class WindowsReleaseRecoveryContractTest(unittest.TestCase):
    def test_every_normal_windows_release_compiles_and_embeds_rollback(self):
        source = NORMAL.read_text(encoding="utf-8")
        title = "Compile mandatory Windows rollback recovery helper"
        self.assertEqual(source.count(title), 1)
        self.assertIn(r"tool\windows_rollback\AivexusRecovery.cs", source)
        self.assertIn(r"tool\windows_rollback\recovery.manifest", source)
        self.assertIn("Recovery helper failed to compile: refusing to publish", source)
        self.assertEqual(source.count("#define AivexusRecoveryHelper"), 1)
        self.assertIn("steps.recovery.outputs.helper", source)
        self.assertLess(source.index(title), source.index("Prepare Windows release payload"))
        self.assertLess(
            source.index("Prepare Windows release payload"),
            source.index("Build versioned Windows Setup.exe"),
        )
        self.assertLess(
            source.index("Build versioned Windows Setup.exe"),
            source.index("Publish Windows installer into matching GitHub Release"),
        )

    def test_dev_1_0_16_is_windows_81_only_with_recovery(self):
        source = NORMAL.read_text(encoding="utf-8")
        inno = INNO.read_text(encoding="utf-8")
        self.assertIn("1.0.16 Dev QA", source)
        self.assertIn("isWin81OnlyDev", source)
        self.assertIn("#define AivexusWin81UnsignedQABuild 1", source)
        self.assertIn("#define AivexusRecoveryHelper", source)
        self.assertIn("Windows 8.1 unsigned QA installation must include", inno)
        self.assertIn("OnlyBelowVersion=10.0", inno)
        pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
        self.assertIn("version: 1.0.16+16", pubspec)

    def test_beta_windows_requires_trusted_signing(self):
        source = BETA.read_text(encoding="utf-8")
        self.assertIn("Require trusted code-signing identity (fail closed)", source)
        self.assertIn("AivexusTrustedSignedBuild", source)
        self.assertIn("AivexusRecoveryHelper", source)
        self.assertIn("SignedUninstaller=yes", INNO.read_text(encoding="utf-8"))

    def test_inno_aborts_before_replacing_first_program_file(self):
        source = INNO.read_text(encoding="utf-8")
        self.assertIn("CloseApplications=yes", source)
        self.assertIn("BeforeInstall: SnapshotInstalledVersion", source)
        self.assertIn("ResultCode <> 0", source)
        self.assertIn("RaiseException('Previous AIVEXUS version", source)
        first_executable = source.index('Source: "{#ReleaseDir}\\ai_orchestrator.exe"')
        backup_hook = source.index("BeforeInstall: SnapshotInstalledVersion")
        other_binaries = source.index('Source: "{#ReleaseDir}\\*"')
        self.assertLess(first_executable, backup_hook)
        self.assertLess(backup_hook, other_binaries)
        self.assertIn("Recupera versione precedente", source)
        self.assertIn("Conferma aggiornamento funzionante", source)
        self.assertIn("--roaming", source)


if __name__ == "__main__":
    unittest.main()
