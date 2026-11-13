import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/windows_computer_use_adapter.dart';

void main() {
  test('read-only Windows accessibility PowerShell syntax parses on runner',
      () async {
    final nativeScript = WindowsComputerUseAdapter.accessibilityScriptForTest;
    expect(nativeScript, isNot(contains('GetCurrentPattern(')));
    expect(nativeScript, isNot(contains('DocumentRange.GetText(')));
    expect(nativeScript, contains('IsPassword'));
    expect(nativeScript, contains(r'if ($queue.Count -gt 0 -or $truncated)'));
    // The template is not executable until the selected HWND is inserted.
    // Parse the same rendered syntax used by the real native adapter.
    expect(nativeScript, contains('__HANDLE__'));
    final rendered = nativeScript.replaceFirst('__HANDLE__', '0');
    final encoded = base64Encode(utf8.encode(rendered));
    final parseOnly = r'''
$source = [System.Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('__ENCODED__'))
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseInput(
    $source, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    throw ($errors | Out-String)
}
Write-Output 'UIA_SOURCE_PARSED'
''';
    final result = await Process.run(
      'powershell.exe',
      <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        parseOnly.replaceFirst('__ENCODED__', encoded),
      ],
    ).timeout(const Duration(seconds: 45));
    // Parser-only. This test never accesses the desktop or sends input.
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout.toString().trim(), 'UIA_SOURCE_PARSED');
  }, skip: !Platform.isWindows);
}
