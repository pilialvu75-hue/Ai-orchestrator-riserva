import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/windows_2048_qa_game_script.dart';

void main() {
  test('standalone 2048 QA script is fixed, offline and accessibility-readable',
      () async {
    const source = kWindows2048QaGameScript;
    expect(source, contains('20261112'));
    expect(source, contains('AccessibleName'));
    expect(source, contains('2048 tile row'));
    expect(source, contains('2048 score'));
    expect(source, contains('Move-Game'));
    expect(source, contains('Test-GameOver'));
    for (final prohibited in <String>[
      'Invoke-Expression',
      'Invoke-WebRequest',
      'System.Net',
      'Start-Process',
      'DownloadString',
      'Remove-Item',
      'Set-ExecutionPolicy',
      'Invoke-RestMethod',
    ]) {
      expect(source, isNot(contains(prohibited)));
    }

    final encoded = base64Encode(utf8.encode(source));
    const parseOnly = r'''
$source = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('__SOURCE__'))
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseInput(
    $source, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    throw ($errors | Out-String)
}
Write-Output 'QA_2048_SCRIPT_PARSED'
''';
    final response = await Process.run(
      'powershell.exe',
      <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        parseOnly.replaceFirst('__SOURCE__', encoded),
      ],
    ).timeout(const Duration(seconds: 45));
    // Syntax only: the CI runner never launches a GUI or plays the game.
    expect(response.exitCode, 0, reason: response.stderr.toString());
    expect(response.stdout.toString().trim(), 'QA_2048_SCRIPT_PARSED');
  }, skip: !Platform.isWindows);
}
