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
  test('2048 Windows game logic is deterministic and supports real moves',
      () async {
    const source = kWindows2048QaGameScript;
    const entrypoint = '[System.Windows.Forms.Application]::Run(\$form)';
    expect(source, contains(entrypoint));
    const headlessChecks = r'''
\$initial = (\$script:board -join ',')
Reset-Game
if ((\$script:board -join ',') -ne \$initial) {
    throw 'Restart did not reproduce the deterministic opening board'
}
Move-Game 'left'
Move-Game 'down'
Move-Game 'right'
Move-Game 'up'
if (\$script:moves -le 0) { throw 'No game move changed the board' }
if (\$script:tileControls.Count -ne 16) {
    throw 'The accessible board must expose exactly 16 tiles'
}
foreach (\$tile in \$script:tileControls) {
    if (\$tile.AccessibleName -notmatch '^2048 tile row') {
        throw 'A tile is not accessible to Computer Use'
    }
}
if (\$script:scoreControl.AccessibleName -notmatch '^2048 score') {
    throw 'Game score is not accessible to Computer Use'
}
Write-Output 'QA_2048_ENGINE_OK'
\$form.Dispose()
''';
    final script = source.replaceFirst(entrypoint, headlessChecks);
    final result = await Process.run(
      'powershell.exe',
      <String>['-NoProfile', '-NonInteractive', '-STA', '-Command', script],
    ).timeout(const Duration(seconds: 45));
    // No interactive window, user data or keyboard/mouse injection in CI.
    expect(result.exitCode, 0,
        reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout.toString(), contains('QA_2048_ENGINE_OK'));
  }, skip: !Platform.isWindows);

}
