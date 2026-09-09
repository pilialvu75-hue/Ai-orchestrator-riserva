import 'dart:convert';

import 'package:ai_orchestrator/core/diagnostics/public_log_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const time = '[2026-09-06T02:57:18.238076]';

  test('never exports arbitrary crash text or credentials', () {
    final line = publicLogProjection(
      '$time [TTS_FAIL] secret=ghp_private /data/user/private '
      'user@example.com',
    );
    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'TTS_FAIL',
      },
    );
  });

  test('ignores tags injected in free text and unknown events', () {
    expect(
      publicLogProjection('$time [LOG] prompt=hello [TTS_FAIL]'),
      isNull,
    );
    expect(publicLogProjection('user text [TTS_FAIL]'), isNull);
  });

  test('exports numeric Android exit details but not abort payload', () {
    final line = publicLogProjection(
      '$time [ANDROID_PROCESS_EXIT_HISTORY] '
      '{"reason_code":5,"status":6,"abort_message":"private prompt",'
      '"process":"private"}',
    );
    expect(jsonDecode(line!)['reason_code'], 5);
    expect(line, isNot(contains('private')));
  });

  test('exports only canonical Cloud provider attempts', () {
    final line = publicLogProjection(
      '$time [TOKEN_STREAM] [TOKEN_STREAM] notice session=default '
      'notice="cloud_provider:claude"',
    );

    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'CLOUD_PROVIDER_ATTEMPT',
        'provider': 'claude',
      },
    );
    expect(line, isNot(contains('session')));
  });

  test('never exports token stream text or unknown provider names', () {
    expect(
      publicLogProjection(
        '$time [TOKEN_STREAM] [TOKEN_STREAM] token=private-conversation',
      ),
      isNull,
    );
    expect(
      publicLogProjection(
        '$time [TOKEN_STREAM] [TOKEN_STREAM] notice session=default '
        'notice="cloud_provider:private-provider"',
      ),
      isNull,
    );
  });

  test('exports terminal outcome without session or response contents', () {
    final success = publicLogProjection(
      '$time [FINAL_RESPONSE] [FINAL_RESPONSE] session=default attempt=1 '
      'isFinal=true isError=false text_len=152',
    );
    final failure = publicLogProjection(
      '$time [FINAL_RESPONSE] [FINAL_RESPONSE] session=private-session attempt=2 '
      'isFinal=true isError=true text_len=0',
    );

    expect(
      jsonDecode(success!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'FINAL_RESPONSE_SUCCESS',
        'is_final': true,
        'text_len': 152,
      },
    );
    expect(
      jsonDecode(failure!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'FINAL_RESPONSE_ERROR',
        'is_final': true,
        'text_len': 0,
      },
    );
    expect(success, isNot(contains('session')));
    expect(failure, isNot(contains('private-session')));
  });

  test('does not mislabel an intermediate response chunk as success', () {
    expect(
      publicLogProjection(
        '$time [FINAL_RESPONSE] [FINAL_RESPONSE] session=default attempt=1 '
        'isFinal=false isError=false text_len=12',
      ),
      isNull,
    );
  });
}
