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

  test('HTTP 429 receipt preserves only safe model class and rate dimension', () {
    CloudRoutingDiagnostics.httpFailure(
      providerId: 'mistral',
      modelId: 'mistral-large-4',
      statusCode: 429,
      retryAfter: const Duration(seconds: 7),
      responseBody: 'Requests per second exceeded for secret=sk-PRIVATE and a@b.com',
    );

    final message = RuntimeEventLog.instance.entries.last.message;
    expect(
      message,
      '[CLOUD_HTTP_FAILURE] provider=mistral status=429 '
      'model_class=large4 retry_after_s=7 limit_hint=rps',
    );
    expect(message, isNot(contains('sk-PRIVATE')));
    expect(message, isNot(contains('a@b.com')));
    expect(message, isNot(contains('Requests per second exceeded')));
  });

  test('unrecognized models and oversized waits are suppressed', () {
    CloudRoutingDiagnostics.httpFailure(
      providerId: 'mistral',
      modelId: 'private-user@example.com',
      statusCode: 429,
      retryAfter: const Duration(days: 3),
      responseBody: 'unexpected private text',
    );
    expect(
      RuntimeEventLog.instance.entries.last.message,
      '[CLOUD_HTTP_FAILURE] provider=mistral status=429 '
      'model_class=other retry_after_s=none limit_hint=unknown',
    );
  });

  test('HTTP 429 extracts monthly vs quota hints without raw response', () {
    CloudRoutingDiagnostics.httpFailure(
      providerId: 'mistral',
      modelId: 'mistral-small-latest',
      statusCode: 429,
      retryAfter: null,
      responseBody: 'Monthly allocation reached. Bearer abcde',
    );
    expect(
      RuntimeEventLog.instance.entries.last.message,
      '[CLOUD_HTTP_FAILURE] provider=mistral status=429 '
      'model_class=small retry_after_s=none limit_hint=monthly',
    );
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
