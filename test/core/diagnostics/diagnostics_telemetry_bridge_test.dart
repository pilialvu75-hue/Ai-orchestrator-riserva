import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/core/diagnostics/diagnostics_telemetry_bridge.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

RuntimeEventEntry _entry(
  String tag,
  String message, {
  RuntimeEventCategory category = RuntimeEventCategory.other,
}) {
  return RuntimeEventEntry(
    timestamp: DateTime(2026, 9, 21),
    category: category,
    tag: tag,
    message: message,
  );
}

void main() {
  group('DiagnosticsTelemetryPolicy', () {
    test('promotes runtime failure without forwarding free-form message', () {
      final promotion = DiagnosticsTelemetryPolicy.promote(
        _entry(
          'AI_RUNTIME_MONITOR',
          '[AI_RUNTIME_MONITOR] ready -> failed '
          'tokens=17 elapsed_ms=9000 '
          'message="private local path / secret prompt"',
          category: RuntimeEventCategory.runtime,
        ),
      );

      expect(promotion, isNotNull);
      expect(promotion!.eventName, 'diagnostic_issue');
      expect(promotion.properties['diagnostic_tag'], 'AI_RUNTIME_MONITOR');
      expect(promotion.properties['status'], 'failed');
      expect(promotion.properties['tokens'], 17);
      expect(promotion.properties['elapsed_ms'], 9000);
      expect(
        promotion.properties.values.join(' '),
        isNot(contains('private local path')),
      );
      expect(
        promotion.properties.values.join(' '),
        isNot(contains('secret prompt')),
      );
    });

    test('keeps normal runtime transitions local only', () {
      final promotion = DiagnosticsTelemetryPolicy.promote(
        _entry(
          'AI_RUNTIME_MONITOR',
          '[AI_RUNTIME_MONITOR] loading -> ready tokens=0 elapsed_ms=1200',
          category: RuntimeEventCategory.runtime,
        ),
      );

      expect(promotion, isNull);
    });

    test('promotes cloud routing failures using closed vocabulary only', () {
      final promotion = DiagnosticsTelemetryPolicy.promote(
        _entry(
          'CLOUD_ROUTING',
          '[CLOUD_ROUTING] task=coding cost=free provider=mistral '
          'decision=failure reason=rate_limit prompt="never export me"',
        ),
      );

      expect(promotion, isNotNull);
      expect(promotion!.properties['decision'], 'failure');
      expect(promotion.properties['reason'], 'rate_limit');
      expect(promotion.properties['provider'], 'mistral');
      expect(promotion.properties, isNot(contains('prompt')));
      expect(
        promotion.properties.values.join(' '),
        isNot(contains('never export me')),
      );
    });

    test('does not duplicate uncaught exceptions already sent as crashes', () {
      final promotion = DiagnosticsTelemetryPolicy.promote(
        _entry(
          'FORENSIC_UNCAUGHT_DART_EXCEPTION',
          '[FORENSIC_UNCAUGHT_DART_EXCEPTION] message=secret',
        ),
      );

      expect(promotion, isNull);
    });

    test('promotes first-token latency without identifiers or text', () {
      final promotion = DiagnosticsTelemetryPolicy.promote(
        _entry(
          'FIRST_TOKEN_REAL',
          '[FIRST_TOKEN_REAL] elapsed_ms=27500 session=private123 '
          'model_path=/storage/private.gguf',
          category: RuntimeEventCategory.inference,
        ),
      );

      expect(promotion, isNotNull);
      expect(promotion!.eventName, 'diagnostic_performance');
      expect(promotion.properties['elapsed_ms'], 27500);
      expect(promotion.properties, isNot(contains('session')));
      expect(promotion.properties, isNot(contains('model_path')));
    });

    test('keeps high-frequency token chatter local', () {
      final promotion = DiagnosticsTelemetryPolicy.promote(
        _entry(
          'TOKEN_EMIT',
          '[TOKEN_EMIT] token_index=17 chars=4 session=private',
          category: RuntimeEventCategory.token,
        ),
      );

      expect(promotion, isNull);
    });
  });
}
