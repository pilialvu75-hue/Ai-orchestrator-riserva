import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/diagnostics/diagnostics_release_body.dart';

void main() {
  String batch(String event, int index) => 'schema=1 build=1506 device=test capture_session=a\n'
      '${jsonEncode({'time': '2026-09-09T12:00:${index.toString().padLeft(6, '0')}', 'event': event})}\n';

  test('ordinary updates preserve previous failures and retry is idempotent', () {
    final first = diagnosticsReleaseBody(batch('TTS_FAIL', 1));
    final second = diagnosticsReleaseBody(batch('MODEL_READY', 2), previousBody: first);
    expect(second, contains('TTS_FAIL'));
    expect(second, contains('MODEL_READY'));
    expect(diagnosticsReleaseBody(batch('MODEL_READY', 2), previousBody: second), second);
  });

  test('bounded routine traffic cannot evict reserved errors', () {
    var body = diagnosticsReleaseBody(batch('TTS_FAIL', 1));
    final many = 'schema=1 build=1507 device=test capture_session=b\n'
        '${List.generate(2000, (i) => jsonEncode({'time': '2026-09-10T${i.toString().padLeft(6, '0')}', 'event': 'MODEL_READY'})).join('\n')}\n';
    body = diagnosticsReleaseBody(many, previousBody: body);
    expect(body.length, lessThan(48000));
    expect(body, contains('TTS_FAIL'));
    expect(body, contains('build=1506'));
    expect(body, contains('build=1507'));
    expect(body, contains('001999'));
  });

  test('migrates old summary and does not publish arbitrary input', () {
    final old = '    schema=1 device=test\n    {"time":"2026","event":"TTS_FAIL"}\n';
    final body = diagnosticsReleaseBody('schema=1 device=test\nsecret raw text\n', previousBody: old);
    expect(body, contains('TTS_FAIL'));
    expect(body, isNot(contains('secret raw text')));
    expect(diagnosticsReleaseBody(''), contains('Eventi recenti'));
  });
}
