import 'package:ai_orchestrator/core/runtime/inference/android/native_generation_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('never exceeds the native context across prompt sizes', () {
    for (var promptTokens = 0; promptTokens < 2200; promptTokens++) {
      final reserve = NativeGenerationBudget.generationReserve(
        context: 2048,
        promptTokens: promptTokens,
        requested: 1024,
        safetyMargin: 32,
      );
      expect(reserve == 0 || promptTokens + reserve + 32 <= 2048, isTrue);
    }
  });
  test('device web prompt reserves only the native capacity', () {
    expect(
      NativeGenerationBudget.generationReserve(
        context: 2048,
        promptTokens: 1188,
        requested: 1024,
        safetyMargin: 32,
      ),
      828,
    );
    expect(
      NativeGenerationBudget.generationReserve(
        context: 2048,
        promptTokens: 2016,
        requested: 1024,
        safetyMargin: 32,
      ),
      0,
    );
    expect(
      NativeGenerationBudget.generationReserve(
        context: 2048,
        promptTokens: -1,
        requested: 1024,
        safetyMargin: 32,
      ),
      0,
    );
    expect(
      NativeGenerationBudget.generationReserve(
        context: 2048,
        promptTokens: 600,
        requested: 256,
        safetyMargin: 32,
      ),
      256,
    );
  });
}
