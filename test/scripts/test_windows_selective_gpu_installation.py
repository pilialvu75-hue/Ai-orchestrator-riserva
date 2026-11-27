"""Static contract for the installer; hardware probing still requires physical QA."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[2] /
          "windows/installer/ai_orchestrator.iss").read_text(encoding="utf-8")


class SelectiveGpuInstallationTest(unittest.TestCase):
    def test_base_payload_cannot_copy_gpu_backends_unconditionally(self):
        base_entries = [line for line in SOURCE.splitlines()
                        if line.startswith(r'Source: "{#ReleaseDir}\*";')]
        self.assertEqual(len(base_entries), 2)
        for entry in base_entries:
            self.assertIn(r'\runtime-cuda\*', entry)
            self.assertIn(r'\runtime-vulkan\*', entry)
        for backend, check in [('cuda', 'InstallCudaRuntime'),
                               ('vulkan', 'InstallVulkanRuntime')]:
            entries = [line for line in SOURCE.splitlines()
                       if line.startswith(f'Source: "{{#ReleaseDir}}\\runtime-{backend}\\*";')]
            self.assertEqual(len(entries), 1)
            self.assertIn(f'Check: {check}', entries[0])

    def test_exact_temporary_probe_and_fail_closed(self):
        for marker in ('GetWindowsVersion >= $0A000000', "DriverCandidate('nvcuda.dll')",
                       "DriverCandidate('vulkan-1.dll')",
                       "ExtractTemporaryFiles('{app}\\runtime-'",
                       "--list-devices", "WaitForExit(15000)",
                       "Result := ResultCode = 0", "Result := False",
                       "if CudaSupported then", "if VulkanSupported then"):
            self.assertIn(marker, SOURCE)
        self.assertNotIn("ExecutionPolicy Bypass", SOURCE)
        self.assertNotIn("DelTree(", SOURCE)

    def test_probe_after_install_consent_and_before_application_copy(self):
        self.assertIn("function PrepareToInstall(var NeedsRestart: Boolean): String;", SOURCE)
        self.assertIn("Check: NeedVCRedistRun", SOURCE)
        self.assertLess(SOURCE.index("BeforeInstall: SnapshotInstalledVersion"),
                        SOURCE.index("Check: InstallCudaRuntime"))
        self.assertLess(SOURCE.index("BeforeInstall: SnapshotInstalledVersion"),
                        SOURCE.index("Check: InstallVulkanRuntime"))
        self.assertIn("RaiseException('Previous AIVEXUS version", SOURCE)


if __name__ == "__main__":
    unittest.main()
