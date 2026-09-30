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

  test('shows cross-platform diagnostics signals in a dedicated section', () {
    final filtered =
        'schema=1 build=2800 device=test platform=windows capture_session=desktop\n'
        '${jsonEncode({
          'time': '2026-09-30T15:00:00.000000',
          'event': 'DIAGNOSTICS_SESSION',
          'platform': 'windows',
          'transport': 'github_releases',
          'enabled': true,
        })}\n'
        '${jsonEncode({
          'time': '2026-09-30T15:01:00.000000',
          'event': 'LOCAL_RUNTIME_ERROR',
          'stage': 'validation',
          'reason': 'unsendable_isolate_object',
          'object': 'custom_zone',
        })}\n'
        '${jsonEncode({
          'time': '2026-09-30T15:02:00.000000',
          'event': 'WINDOWS_NATIVE_TRACE',
          'source': 'previous',
          'last_stage': '24',
          'fatal': true,
          'clean_shutdown': false,
          'exception_code': '0XC0000005',
          'fault_module': 'ucrtbase.dll',
        })}\n';

    final body = diagnosticsReleaseBody(filtered);
    expect(body, contains('### Stato piattaforma / diagnostica remota'));
    expect(body, contains('DIAGNOSTICS_SESSION'));
    expect(body, contains('LOCAL_RUNTIME_ERROR'));
    expect(body, contains('WINDOWS_NATIVE_TRACE'));
    expect(body, contains('### Ultimi errori e arresti'));
    expect(body, contains('0XC0000005'));
  });

  test('shows local benchmark events in a dedicated section', () {
    final filtered =
        'schema=1 build=2475 device=test capture_session=bench\n'
        '${jsonEncode({
          'time': '2026-09-25T14:30:00.000000',
          'event': 'LOCAL_MODEL_BENCH_CASE',
          'model': 'phi3_5_mini',
          'case': 'vulkan_fact',
          'score': 2,
          'max_score': 2,
        })}\n'
        '${jsonEncode({
          'time': '2026-09-25T14:31:00.000000',
          'event': 'LOCAL_MODEL_BENCH_MODEL_END',
          'model': 'phi3_5_mini',
          'score': 9,
          'max_score': 11,
        })}\n';

    final body = diagnosticsReleaseBody(filtered);
    expect(body, contains('### Benchmark locali'));
    expect(body, contains('LOCAL_MODEL_BENCH_CASE'));
    expect(body, contains('LOCAL_MODEL_BENCH_MODEL_END'));
  });

  test('migrates old summary and does not publish arbitrary input', () {
    final old = '    schema=1 device=test\n    {"time":"2026","event":"TTS_FAIL"}\n';
    final body = diagnosticsReleaseBody('schema=1 device=test\nsecret raw text\n', previousBody: old);
    expect(body, contains('TTS_FAIL'));
    expect(body, isNot(contains('secret raw text')));
    expect(diagnosticsReleaseBody(''), contains('Eventi recenti'));
  });
}
