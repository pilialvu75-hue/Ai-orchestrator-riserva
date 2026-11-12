import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/windows_computer_use_adapter.dart';

void main() {
  test(
    'Windows native interop compiles and binds clicks to a selected window',
    () async {
      final source = WindowsComputerUseAdapter.inputInteropSourceForTest;
      // Never adopt whichever application happens to be under a click.
      expect(source, contains('if (root != expected)'));
      expect(source, contains('GetForegroundWindow() != expected'));
      final script = '${source}\n' + r'''
$click = [AivexusDesktopInput].GetMethod('Click')
if ($null -eq $click) { throw 'Expected native Click method' }
$parameters = $click.GetParameters()
if ($parameters.Count -ne 3 -or
    $parameters[2].Name -ne 'expectedHandle' -or
    $click.ReturnType -ne [void]) {
    throw 'Click must require an expected selected window handle'
}
$invalidHandleRejected = $false
try {
    [AivexusDesktopInput]::Click(0, 0, 0)
} catch {
    if ($_.Exception.Message -like '*selected window is invalid*') {
        $invalidHandleRejected = $true
    }
}
if (-not $invalidHandleRejected) {
    throw 'Click did not reject an invalid target before any input'
}
$selector = [AivexusDesktopInput].GetMethod('SelectObservedWindowAt')
if ($null -eq $selector -or
    $selector.GetParameters().Count -ne 4 -or
    $selector.GetParameters()[2].Name -ne 'observedHandle' -or
    $selector.ReturnType -ne [long]) {
    throw 'Cross-window selector must bind to screenshot-observed HWND'
}
$invalidObservedRejected = $false
try {
    [AivexusDesktopInput]::SelectObservedWindowAt(20, 20, 0, 31415) |
        Out-Null
} catch {
    if ($_.Exception.Message -like '*Observed window is invalid*') {
        $invalidObservedRejected = $true
    }
}
if (-not $invalidObservedRejected) {
    throw 'The observed-window selector did not reject a missing target'
}
Write-Output 'INTEROP_COMPILED'
''';
      final result = await Process.run(
        'powershell.exe',
        <String>['-NoProfile', '-NonInteractive', '-Command', script],
      ).timeout(const Duration(seconds: 45));

      // No mouse/keyboard input is sent: compile and inspect C# only.
      expect(result.exitCode, 0,
          reason: 'The fixed Windows native input interop failed validation.');
      expect(result.stdout.toString().trim(), 'INTEROP_COMPILED');
    },
    skip: !Platform.isWindows,
  );
}
