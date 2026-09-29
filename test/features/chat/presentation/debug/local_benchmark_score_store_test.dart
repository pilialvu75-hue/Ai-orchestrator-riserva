import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/local_benchmark_score_store.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/local_model_benchmark.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const model = AiModel(
    id: 'phi_test',
    displayName: 'Phi Test',
    fileName: 'phi-test-q4.gguf',
    downloadUrl: '',
    version: '1.0.0',
    sizeBytes: 2048,
    description: 'test model',
    sizeCategory: '4B',
    isDownloaded: true,
    localPath: '/models/phi-test-q4.gguf',
    validationStatus: ModelValidationStatus.validatedOk,
  );

  LocalModelBenchmarkCaseResult perfectCase() =>
      const LocalModelBenchmarkCaseResult(
        caseId: 'sample',
        response: 'ok',
        score: 2,
        maxScore: 2,
        forbiddenHits: 0,
        firstContentMs: 500,
        totalMs: 1500,
        reportedTokens: 15,
        prefillMs: 250,
        observedGpuLayers: 33,
        observedBatch: 128,
        observedMicroBatch: 32,
        startPressure: 'normal',
        endPressure: 'normal',
        startAvailableBytes: 1000,
        endAvailableBytes: 900,
        startBatteryTemperatureDeciC: 300,
        endBatteryTemperatureDeciC: 305,
        sessionStart: 'cold',
        sessionEnd: 'kept',
      );

  test('quick score reaches 100 for perfect, fast result', () {
    final result = LocalModelBenchmarkModelResult(
      modelId: model.effectiveRuntimeModelId,
      catalogModelId: model.id,
      displayName: model.displayName,
      cases: <LocalModelBenchmarkCaseResult>[perfectCase()],
    );

    expect(LocalBenchmarkScoring.quickScore(result), 100);
  });

  test('score store persists matching model fingerprint', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = LocalBenchmarkScoreStore(preferences);

    await store.saveComponent(
      model: model,
      component: LocalBenchmarkComponent.quick,
      score: 82,
      updatedAt: DateTime.utc(2026, 9, 29),
    );

    final loaded = await store.loadForModels(const <AiModel>[model]);
    expect(loaded[model.id]?.generalScore, 82);
    expect(loaded[model.id]?.completedComponents, 1);
  });

  test('score store ignores stale score after model fingerprint changes',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = LocalBenchmarkScoreStore(preferences);

    await store.saveComponent(
      model: model,
      component: LocalBenchmarkComponent.quick,
      score: 82,
    );

    final changed = model.copyWith(
      fileName: 'phi-test-q5.gguf',
      sizeBytes: 4096,
    );
    final loaded = await store.loadForModels(<AiModel>[changed]);

    expect(loaded.containsKey(model.id), isFalse);
  });

  test('general score combines only completed components by weight', () {
    final score = LocalModelBenchmarkScore(
      modelId: model.id,
      fingerprint: LocalBenchmarkScoreStore.fingerprintFor(model),
      components: <LocalBenchmarkComponent, LocalBenchmarkComponentScore>{
        LocalBenchmarkComponent.quick: LocalBenchmarkComponentScore(
          score: 80,
          updatedAt: DateTime.utc(2026, 9, 29),
        ),
        LocalBenchmarkComponent.quality: LocalBenchmarkComponentScore(
          score: 100,
          updatedAt: DateTime.utc(2026, 9, 29),
        ),
      },
    );

    // (80*10 + 100*25) / 35 = 94.285...
    expect(score.generalScore, 94);
    expect(score.completedComponents, 2);
  });
}
