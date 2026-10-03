import 'dart:convert';

import 'package:ai_orchestrator/core/diagnostics/public_log_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const time = '[2026-09-06T02:57:18.238076]';

  test('exports platform diagnostics session without device identity', () {
    final line = publicLogProjection(
      '$time [DIAGNOSTICS_SESSION] '
      'platform=windows transport=github_releases enabled=true',
    );

    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'DIAGNOSTICS_SESSION',
        'platform': 'windows',
        'transport': 'github_releases',
        'enabled': true,
      },
    );
  });

  test('exports classified unsendable runtime object without exception text',
      () {
    final line = publicLogProjection(
      '$time [LOCAL_RUNTIME_ERROR] '
      'stage=validation reason=unsendable_isolate_object '
      'object=custom_zone',
    );

    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'LOCAL_RUNTIME_ERROR',
        'stage': 'validation',
        'reason': 'unsendable_isolate_object',
        'object': 'custom_zone',
      },
    );
  });

  test('rejects extended runtime diagnostics payloads', () {
    expect(
      publicLogProjection(
        '$time [LOCAL_RUNTIME_ERROR] '
        'stage=validation reason=unsendable_isolate_object '
        'object=timer message=private-path',
      ),
      isNull,
    );
  });

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

  test('exports closed managed crash categories without exception text', () {
    for (final cause in [
      'foreground_start_timeout',
      'foreground_start_disallowed',
      'foreground_bad_notification',
      'security_exception',
      'managed_other',
      'private exception message'
    ]) {
      final line = publicLogProjection('$time [ANDROID_PROCESS_EXIT_HISTORY] '
          '${jsonEncode({
            'reason_code': 4,
            'managed_cause': cause,
            'description': 'private exception message'
          })}');
      expect(jsonDecode(line!)['managed_cause'],
          cause.startsWith('private') ? isNull : cause);
      expect(line, isNot(contains('private')));
    }
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

  test('exports first-token extension metrics without session identity', () {
    final line = publicLogProjection(
      '$time [FIRST_TOKEN_DEADLINE_EXTENDED] '
      'session=private-review-session elapsed_ms=51000 '
      'soft_timeout_ms=45000 hard_timeout_ms=90000 '
      'decode_baseline=4 decode_current=10 reason=native_decode_progress',
    );

    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-06T02:57:18.238076',
        'event': 'FIRST_TOKEN_DEADLINE_EXTENDED',
        'elapsed_ms': 51000,
        'soft_timeout_ms': 45000,
        'hard_timeout_ms': 90000,
        'decode_baseline': 4,
        'decode_current': 10,
        'reason': 'native_decode_progress',
      },
    );
    expect(line, isNot(contains('private-review-session')));
  });

  test('rejects malformed first-token extension telemetry', () {
    expect(
      publicLogProjection(
        '$time [FIRST_TOKEN_DEADLINE_EXTENDED] '
        'session=private elapsed_ms=51000 soft_timeout_ms=45000 '
        'hard_timeout_ms=90000 decode_baseline=4 decode_current=10 '
        'reason=private',
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

  test('exports Engineer prompt-budget recovery metrics without private IDs',
      () {
    final retry = publicLogProjection('$time [WORKSHOP_ENGINEER_RETRY] '
        'request=private-request execution=private-execution attempt=2 '
        'reason=prompt_budget terminal=failed');
    final decoded = jsonDecode(retry!) as Map<String, dynamic>;
    expect(decoded['reason'], 'prompt_budget');
    expect(decoded['attempt'], 2);
    expect(retry, isNot(contains('private')));
    final prompt = publicLogProjection('$time [WORKSHOP_ENGINEER_PROMPT] '
        'request=private-request compact=true chars=3300 workspace_files=1 '
        'replaceable_targets=2 architect_chars=900');
    final metrics = jsonDecode(prompt!) as Map<String, dynamic>;
    expect(metrics['replaceable_targets'], 2);
    expect(metrics['architect_chars'], 900);
    expect(prompt, isNot(contains('private')));
    expect(
        publicLogProjection('$time [WORKSHOP_ENGINEER_RETRY] '
            'request=req attempt=2 reason=prompt_budget terminal=failed prompt=private'),
        isNull);
  });

  test('exports only closed planner metrics and JSON recovery categories', () {
    const events = <String, Map<String, Object>>{
      '[WORKSHOP_PLANNER_PROMPT] attempt=2 build_repair=true chars=3210':
          <String, Object>{'attempt': 2, 'build_repair': true, 'chars': 3210},
      '[WORKSHOP_PLANNER_OUTPUT] attempt=2 terminal=success chars=512':
          <String, Object>{'attempt': 2, 'terminal': 'success', 'chars': 512},
      '[WORKSHOP_PLANNER_JSON] recovery=trailing_comma': <String, Object>{
        'recovery': 'trailing_comma'
      },
      '[WORKSHOP_PLANNER_JSON] recovery=single_object': <String, Object>{
        'recovery': 'single_object'
      },
      '[WORKSHOP_PLANNER_JSON] rejected=ambiguous_objects': <String, Object>{
        'rejected': 'ambiguous_objects'
      },
      '[WORKSHOP_PLANNER_JSON] rejected=incomplete_json': <String, Object>{
        'rejected': 'incomplete_json'
      },
      '[WORKSHOP_PLANNER_JSON] rejected=invalid_json': <String, Object>{
        'rejected': 'invalid_json'
      },
    };
    for (final entry in events.entries) {
      final projected = publicLogProjection('$time ${entry.key}');
      final decoded = jsonDecode(projected!) as Map<String, dynamic>;
      for (final field in entry.value.entries) {
        expect(decoded[field.key], field.value);
      }
      expect(publicLogProjection('$time ${entry.key} raw=private'), isNull);
    }
    for (final payload in <String>[
      '[WORKSHOP_PLANNER_PROMPT] attempt=3 build_repair=true chars=200',
      '[WORKSHOP_PLANNER_OUTPUT] attempt=2 terminal=private chars=20',
      '[WORKSHOP_PLANNER_JSON] recovery=private',
      '[WORKSHOP_PLANNER_JSON] rejected=invalid_json\nprivate output',
    ]) {
      expect(publicLogProjection('$time $payload'), isNull);
    }
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

  test('exports current batch Reviewer telemetry with closed fields', () {
    final events = <String, Map<String, Object>>{
      '[WORKSHOP_REVIEW_PROMPT] compact=true batch=1/2 chars=1800 '
          'files=2 coverage=abcd0123 plan_chars=900': {
        'compact': true,
        'batch': 1,
        'batches': 2,
        'chars': 1800,
        'files': 2,
        'coverage': 'abcd0123',
        'plan_chars': 900,
      },
      '[WORKSHOP_REVIEW_RETRY] batch=1/2 attempt=2 '
          'reason=malformed_output terminal=success chars=3': {
        'batch': 1,
        'batches': 2,
        'attempt': 2,
        'reason': 'malformed_output',
        'terminal': 'success',
        'chars': 3,
      },
      '[WORKSHOP_REVIEW_JSON] batch=1/2 rejected=invalid_verdict chars=3': {
        'batch': 1,
        'batches': 2,
        'rejected': 'invalid_verdict',
        'chars': 3,
      },
      '[WORKSHOP_REVIEW_BATCH_VERDICT] batch=1/2 approved=true '
          'files=2 coverage=abcd0123': {
        'batch': 1,
        'batches': 2,
        'approved': true,
        'files': 2,
        'coverage': 'abcd0123',
      },
      '[WORKSHOP_REVIEW_VERDICT] approved=true files=3 batches=2 '
          'coverage=abcd0123 findings=0 warnings=1': {
        'approved': true,
        'files': 3,
        'batches': 2,
        'coverage': 'abcd0123',
        'findings': 0,
        'warnings': 1,
      },
    };
    for (final entry in events.entries) {
      final projected = jsonDecode(publicLogProjection('$time ${entry.key}')!);
      for (final field in entry.value.entries) {
        expect(projected[field.key], field.value, reason: entry.key);
      }
      expect(publicLogProjection('$time ${entry.key} raw=private'), isNull);
      expect(publicLogProjection('$time ${entry.key}\nprivate'), isNull);
    }
    expect(
        publicLogProjection('$time [WORKSHOP_REVIEW_JSON] '
            'batch=1/2 rejected=private chars=3'),
        isNull);
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

  test('exports closed physical Cantiere acceptance telemetry', () {
    final line = publicLogProjection(
      '$time [WORKSHOP_DEVICE_ACCEPTANCE] '
      'status=passed failure_stage=none completed_tasks=3 total_tasks=3 '
      'install_attempted=true installer_opened=true app_opened=true '
      'host_commit=${List<String>.filled(40, 'a').join()} '
      'artifact_sha=${List<String>.filled(64, 'b').join()}',
    );

    final decoded = jsonDecode(line!);
    expect(decoded['event'], 'WORKSHOP_DEVICE_ACCEPTANCE');
    expect(decoded['status'], 'passed');
    expect(decoded['failure_stage'], 'none');
    expect(decoded['completed_tasks'], 3);
    expect(decoded['installer_opened'], isTrue);
    expect(
      decoded['host_commit'],
      List<String>.filled(40, 'a').join(),
    );
    expect(
      decoded['artifact_sha'],
      List<String>.filled(64, 'b').join(),
    );
  });

  test('rejects physical acceptance telemetry with appended private text', () {
    expect(
      publicLogProjection(
        '$time [WORKSHOP_DEVICE_ACCEPTANCE] '
        'status=failed failure_stage=modelRuntime '
        'completed_tasks=1 total_tasks=3 install_attempted=false '
        'installer_opened=false app_opened=unknown '
        'host_commit=unknown artifact_sha=none prompt=private',
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
    final known = publicLogProjection(
        '$time [VOICE_ENGINE] [TTS_FAIL] reason=non_finite_pcm');
    expect(jsonDecode(known!)['error'], 'non_finite_pcm');
    final private = publicLogProjection(
        '$time [VOICE_ENGINE] [TTS_FAIL] reason=private-secret');
    expect(private, isNot(contains('private-secret')));
  });
}
