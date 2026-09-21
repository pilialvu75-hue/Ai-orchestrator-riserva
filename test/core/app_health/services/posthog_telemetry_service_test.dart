import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/core/app_health/services/posthog_telemetry_service.dart';

void main() {
  test('disabled PostHog telemetry remains fail-safe', () async {
    final service = await PostHogTelemetryService.create(
      projectToken: '',
      enabled: false,
    );

    expect(service.remoteEnabled, isFalse);
    expect(
      () => service.logEvent(
        'test event',
        parameters: <String, Object>{
          'prompt': 'must not be sent',
          'duration_ms': 42,
        },
      ),
      returnsNormally,
    );
    expect(
      () => service.logError(
        StateError('sensitive text'),
        reason: 'unit_test',
      ),
      returnsNormally,
    );

    final trace = service.startTrace('unit test trace');
    expect(trace.stop, returnsNormally);
  });
}
