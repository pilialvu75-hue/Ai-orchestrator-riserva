import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/windows_computer_use_adapter.dart';

void main() {
  test(
    'Windows native input interop compiles on the actual Windows CI runner',
    () async {
      final script =
          '${WindowsComputerUseAdapter.inputInteropSourceForTest}\n'
          "Write-Output 'INTEROP_COMPILED'\n";
      final result = await Process.run(
        'powershell.exe',
        <String>['-NoProfile', '-NonInteractive', '-Command', script],
      ).timeout(const Duration(seconds: 45));

      // No mouse/keyboard input is sent: only compile the fixed C# interop.
      expect(result.exitCode, 0,
          reason: 'The fixed Windows native input interop failed to compile.');
      expect(result.stdout.toString().trim(), 'INTEROP_COMPILED');
    },
    skip: !Platform.isWindows,
  );
}
