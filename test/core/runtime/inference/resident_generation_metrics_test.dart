import 'package:ai_orchestrator/core/runtime/inference/resident_completion_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native generation statistics preserve measured values', () {
    final metrics = ResidentGenerationMetrics.fromTimings({
      'predicted_n': 42,
      'predicted_ms': 2100.5,
      'predicted_per_second': 19.99,
    });
    expect(metrics.generatedTokens, 42);
    expect(metrics.decodeMilliseconds, 2100.5);
    expect(metrics.tokensPerSecond, 19.99);
  });

  test('measured zero is distinct from unknown', () {
    final metrics = ResidentGenerationMetrics.fromTimings({
      'predicted_n': 0,
      'predicted_ms': 0,
      'predicted_per_second': 0,
    });
    expect(metrics.generatedTokens, 0);
    expect(metrics.decodeMilliseconds, 0);
    expect(metrics.tokensPerSecond, 0);
    for (final input in [null, 'bad', <String, Object?>{}]) {
      final unknown = ResidentGenerationMetrics.fromTimings(input);
      expect(unknown.generatedTokens, isNull);
      expect(unknown.decodeMilliseconds, isNull);
      expect(unknown.tokensPerSecond, isNull);
    }
  });

  test('invalid values are never substituted with estimates', () {
    for (final value in [-1, double.nan, double.infinity, '42', true]) {
      final metrics = ResidentGenerationMetrics.fromTimings({
        'predicted_n': value,
        'predicted_ms': value,
        'predicted_per_second': value,
      });
      expect(metrics.generatedTokens, isNull);
      expect(metrics.decodeMilliseconds, isNull);
      expect(metrics.tokensPerSecond, isNull);
    }
    expect(ResidentGenerationMetrics.fromTimings({
      'predicted_n': 1.5,
    }).generatedTokens, isNull);
  });
}
