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

  test('exports current built-in Cloud provider attempts', () {
    final line = publicLogProjection(
      '$time [TOKEN_STREAM] [TOKEN_STREAM] notice session=default '
      'notice="cloud_provider:nvidiaNim"',
    );

    expect(jsonDecode(line!)['provider'], 'nvidiaNim');
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

  test('exports closed Cloud routing fields without conversation data', () {
    final line = publicLogProjection(
      '$time [CLOUD_ROUTING] task=coding cost=paid provider=openAi '
      'decision=attempt reason=dispatch',
    );

    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'CLOUD_ROUTING',
        'task': 'coding',
        'cost': 'paid',
        'provider': 'openAi',
        'decision': 'attempt',
        'reason': 'dispatch',
      },
    );
  });

  test('exports only the generic label for custom Cloud providers', () {
    final line = publicLogProjection(
      '$time [CLOUD_ROUTING] task=reasoning cost=freeTier provider=custom '
      'decision=success reason=completed',
    );

    expect(jsonDecode(line!)['provider'], 'custom');
    expect(line, isNot(contains('private-provider')));
  });

  test('rejects malformed or extended Cloud routing events', () {
    expect(
      publicLogProjection(
        '$time [CLOUD_ROUTING] task=coding cost=paid '
        'provider=private-provider decision=attempt reason=dispatch',
      ),
      isNull,
    );
    expect(
      publicLogProjection(
        '$time [CLOUD_ROUTING] task=coding cost=paid provider=openAi '
        'decision=failure reason=secret-error',
      ),
      isNull,
    );
    expect(
      publicLogProjection(
        '$time [CLOUD_ROUTING] task=coding cost=paid provider=openAi '
        'decision=attempt reason=dispatch prompt=private',
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
  test('exports safe bounded Cantiere Engineer prompt metrics', () {
    final line = publicLogProjection(
      '$time [WORKSHOP_ENGINEER_PROMPT] '
      'request=private-project-id compact=true chars=1432 '
      'workspace_files=3 architect_chars=600',
    );

    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'WORKSHOP_ENGINEER_PROMPT',
        'compact': true,
        'chars': 1432,
        'workspace_files': 3,
        'architect_chars': 600,
      },
    );
    expect(line, isNot(contains('private-project-id')));
  });

  test('exports Engineer retry outcome without request or execution IDs', () {
    final line = publicLogProjection(
      '$time [WORKSHOP_ENGINEER_RETRY] '
      'request=private-request execution=private-execution '
      'attempt=2 terminal=failed',
    );

    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'WORKSHOP_ENGINEER_RETRY',
        'attempt': 2,
        'terminal': 'failed',
      },
    );
    expect(line, isNot(contains('private-request')));
    expect(line, isNot(contains('private-execution')));
  });

  test('rejects malformed Cantiere Engineer telemetry', () {
    expect(
      publicLogProjection(
        '$time [WORKSHOP_ENGINEER_PROMPT] '
        'request=req compact=true chars=10 workspace_files=1 '
        'architect_chars=10 prompt=private',
      ),
      isNull,
    );
    expect(
      publicLogProjection(
        '$time [WORKSHOP_ENGINEER_RETRY] '
        'request=req attempt=2 terminal=secret',
      ),
      isNull,
    );
  });

  test('exports current Engineer retry reason without private IDs', () {
    final line = publicLogProjection(
      '$time [WORKSHOP_ENGINEER_RETRY] request=private-request '
      'execution=private-execution attempt=2 reason=malformed_output '
      'terminal=success chars=731',
    );

    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'WORKSHOP_ENGINEER_RETRY',
        'attempt': 2,
        'reason': 'malformed_output',
        'terminal': 'success',
        'chars': 731,
      },
    );
    expect(line, isNot(contains('private-request')));
    expect(line, isNot(contains('private-execution')));
  });

  test('exports bounded Engineer memory-pressure retry reason', () {
    final line = publicLogProjection(
      '$time [WORKSHOP_ENGINEER_RETRY] request=private-request '
      'execution=private-execution attempt=2 reason=memory_pressure '
      'terminal=failed',
    );

    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'WORKSHOP_ENGINEER_RETRY',
        'attempt': 2,
        'reason': 'memory_pressure',
        'terminal': 'failed',
      },
    );
    expect(line, isNot(contains('private-request')));
    expect(line, isNot(contains('private-execution')));
  });

  test('exports bounded Reviewer and Validation telemetry', () {
    final reviewPrompt = publicLogProjection(
      '$time [WORKSHOP_REVIEW_PROMPT] compact=false chars=2150 '
      'files=1 plan_chars=680',
    );
    final reviewRetry = publicLogProjection(
      '$time [WORKSHOP_REVIEW_RETRY] attempt=2 terminal=failed chars=0',
    );
    final reviewVerdict = publicLogProjection(
      '$time [WORKSHOP_REVIEW_VERDICT] approved=false summary_chars=42 '
      'findings=1 warnings=0',
    );
    final validationVerdict = publicLogProjection(
      '$time [WORKSHOP_VALIDATION_VERDICT] valid=true summary_chars=33 '
      'checks=2 warnings=1',
    );
    final repair = publicLogProjection(
      '$time [WORKSHOP_GATE_REPAIR] source=review attempt=1 '
      'summary_chars=42 issues=1 warnings=0',
    );

    expect(jsonDecode(reviewPrompt!)['event'], 'WORKSHOP_REVIEW_PROMPT');
    expect(jsonDecode(reviewPrompt)['files'], 1);
    expect(jsonDecode(reviewRetry!)['terminal'], 'failed');
    expect(jsonDecode(reviewVerdict!)['approved'], isFalse);
    expect(jsonDecode(reviewVerdict)['findings'], 1);
    expect(jsonDecode(validationVerdict!)['valid'], isTrue);
    expect(jsonDecode(validationVerdict)['checks'], 2);
    expect(jsonDecode(repair!)['source'], 'review');
    expect(jsonDecode(repair)['attempt'], 1);
  });

  test('rejects extended Reviewer telemetry that could carry private text', () {
    expect(
      publicLogProjection(
        '$time [WORKSHOP_REVIEW_VERDICT] approved=false summary_chars=42 '
        'findings=1 warnings=0 summary=private',
      ),
      isNull,
    );
    expect(
      publicLogProjection(
        '$time [WORKSHOP_GATE_REPAIR] source=review attempt=1 '
        'summary_chars=42 issues=1 warnings=0 feedback=private',
      ),
      isNull,
    );
  });

  test('exports TTS worker lifecycle without arbitrary payload', () {
    final line = publicLogProjection(
      '$time [VOICE_ENGINE] [TTS_WORKER_BEGIN] '
      'generation=9 secret=ghp_private /data/user/private',
    );
    expect(
      jsonDecode(line!),
      {
        'time': '2026-09-06T02:57:18.238076',
        'event': 'TTS_WORKER_BEGIN',
      },
    );
    expect(line, isNot(contains('private')));
    expect(line, isNot(contains('generation')));
  });

  test('exports only closed TTS failure reasons', () {
    final known = publicLogProjection('$time [VOICE_ENGINE] [TTS_FAIL] reason=non_finite_pcm');
    expect(jsonDecode(known!)['error'], 'non_finite_pcm');
    final private = publicLogProjection('$time [VOICE_ENGINE] [TTS_FAIL] reason=private-secret');
    expect(private, isNot(contains('private-secret')));
  });
}
