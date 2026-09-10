import 'package:ai_orchestrator/core/diagnostics/cloud_routing_diagnostics.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    RuntimeEventLog.instance.clear();
  });

  test('records task cost provider and dispatch without request content', () {
    CloudRoutingDiagnostics.attempt(
      providerId: 'openAi',
      taskType: 'coding',
    );

    expect(
      RuntimeEventLog.instance.entries.last.message,
      '[CLOUD_ROUTING] task=coding cost=paid provider=openAi '
      'decision=attempt reason=dispatch',
    );
  });

  test('unknown provider and task are reduced to safe closed values', () {
    CloudRoutingDiagnostics.success(
      providerId: 'private-provider-id',
      taskType: 'private-task-name',
    );

    final message = RuntimeEventLog.instance.entries.last.message;
    expect(
      message,
      '[CLOUD_ROUTING] task=general cost=unknown provider=custom '
      'decision=success reason=completed',
    );
    expect(message, isNot(contains('private-provider-id')));
    expect(message, isNot(contains('private-task-name')));
  });

  test('failure reason is classified without exporting failure text', () {
    CloudRoutingDiagnostics.failure(
      providerId: 'gemini',
      taskType: 'reasoning',
      failure: const ServerFailure(
        '429 rate limit for private-user@example.com secret=abc',
      ),
    );

    final message = RuntimeEventLog.instance.entries.last.message;
    expect(
      message,
      '[CLOUD_ROUTING] task=reasoning cost=freeTier provider=gemini '
      'decision=failure reason=rate_limit',
    );
    expect(message, isNot(contains('private-user@example.com')));
    expect(message, isNot(contains('secret=abc')));
  });

  test('network failures use the fixed network reason', () {
    CloudRoutingDiagnostics.failure(
      providerId: 'openAi',
      taskType: 'coding',
      failure: const NetworkFailure('private connection details'),
    );

    expect(
      RuntimeEventLog.instance.entries.last.message,
      '[CLOUD_ROUTING] task=coding cost=paid provider=openAi '
      'decision=failure reason=network',
    );
  });
}
