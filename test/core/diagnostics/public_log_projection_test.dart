import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/diagnostics/public_log_projection.dart';

void main() {
  const time = '[2026-09-06T02:57:18.238076]';
  test('never exports arbitrary crash text or credentials', () {
    final line = publicLogProjection('$time [TTS_FAIL] secret=ghp_private /data/user/private user@example.com');
    expect(jsonDecode(line!), {'time': '2026-09-06T02:57:18.238076', 'event': 'TTS_FAIL'});
  });
  test('ignores tags injected in free text and unknown events', () {
    expect(publicLogProjection('$time [LOG] prompt=hello [TTS_FAIL]'), isNull);
    expect(publicLogProjection('user text [TTS_FAIL]'), isNull);
  });
  test('exports numeric Android exit details but not abort payload', () {
    final line = publicLogProjection('$time [ANDROID_PROCESS_EXIT_HISTORY] '
      '{"reason_code":5,"status":6,"abort_message":"private prompt","process":"private"}');
    expect(jsonDecode(line!)['reason_code'], 5);
    expect(line, isNot(contains('private')));
  });
}
