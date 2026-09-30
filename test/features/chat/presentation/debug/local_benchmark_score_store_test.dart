import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/local_benchmark_score_store.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/local_model_benchmark.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  LocalBenchmarkScoreStore storeFor(
    PreferencesService preferences, {
    String hardwareProfile = 'android|s24fe-test',
  }) =>
      LocalBenchmarkScoreStore(
        preferences,
        hardwareProfileProvider: () async => hardwareProfile,
      );

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

  test('quality score is raw quality percentage only', () {
    final result = LocalModelBenchmarkModelResult(
      modelId: model.effectiveRuntimeModelId,
      catalogModelId: model.id,
      displayName: model.displayName,
      cases: <LocalModelBenchmarkCaseResult>[
        perfectCase(),
        const LocalModelBenchmarkCaseResult(
          caseId: 'partial',
          response: 'partial',
          score: 1,
          maxScore: 2,
          forbiddenHits: 0,
          firstContentMs: 9000,
          totalMs: 20000,
          reportedTokens: 20,
          prefillMs: 5000,
          observedGpuLayers: 0,
          observedBatch: 64,
          observedMicroBatch: 16,
          startPressure: 'normal',
          endPressure: 'high',
          startAvailableBytes: 1000,
          endAvailableBytes: 600,
          startBatteryTemperatureDeciC: 300,
          endBatteryTemperatureDeciC: 330,
          sessionStart: 'cold',
          sessionEnd: 'kept',
        ),
      ],
    );

    expect(LocalBenchmarkScoring.qualityScore(result), 75);
  });

  test('performance score reaches 100 at fixed best thresholds', () {
    LocalModelBenchmarkCaseResult sample({
      required int firstMs,
      required int prefillMs,
      required String sessionStart,
    }) =>
        LocalModelBenchmarkCaseResult(
          caseId: 'performance_generation',
          response: 'benchmark response',
          score: 0,
          maxScore: 0,
          forbiddenHits: 0,
          firstContentMs: firstMs,
          totalMs: firstMs + 2000,
          reportedTokens: 40,
          prefillMs: prefillMs,
          observedGpuLayers: 33,
          observedBatch: 128,
          observedMicroBatch: 32,
          startPressure: 'normal',
          endPressure: 'normal',
          startAvailableBytes: 1000,
          endAvailableBytes: 900,
          startBatteryTemperatureDeciC: 300,
          endBatteryTemperatureDeciC: 305,
          sessionStart: sessionStart,
          sessionEnd: 'kept',
        );

    final result = LocalModelPerformanceModelResult(
      modelId: model.effectiveRuntimeModelId,
      catalogModelId: model.id,
      displayName: model.displayName,
      samples: <LocalModelPerformanceSample>[
        LocalModelPerformanceSample(
          phase: LocalModelPerformancePhase.cold,
          repetition: 1,
          result: sample(
            firstMs: 1500,
            prefillMs: 400,
            sessionStart: 'cold',
          ),
        ),
        LocalModelPerformanceSample(
          phase: LocalModelPerformancePhase.warm,
          repetition: 1,
          result: sample(
            firstMs: 750,
            prefillMs: 400,
            sessionStart: 'warm',
          ),
        ),
        LocalModelPerformanceSample(
          phase: LocalModelPerformancePhase.warm,
          repetition: 2,
          result: sample(
            firstMs: 750,
            prefillMs: 400,
            sessionStart: 'warm',
          ),
        ),
      ],
    );

    expect(result.coldSessionConfirmed, isTrue);
    expect(result.warmSessionConfirmed, isTrue);
    expect(LocalBenchmarkScoring.performanceScore(result), 100);
  });

  test('unconfirmed cold-warm sessions do not produce a valid score', () {
    const sample = LocalModelBenchmarkCaseResult(
      caseId: 'performance_generation',
      response: 'benchmark response',
      score: 0,
      maxScore: 0,
      forbiddenHits: 0,
      firstContentMs: 750,
      totalMs: 2750,
      reportedTokens: 40,
      prefillMs: 400,
      observedGpuLayers: 33,
      observedBatch: 128,
      observedMicroBatch: 32,
      startPressure: 'normal',
      endPressure: 'normal',
      startAvailableBytes: 1000,
      endAvailableBytes: 900,
      startBatteryTemperatureDeciC: 300,
      endBatteryTemperatureDeciC: 305,
      sessionStart: 'unknown',
      sessionEnd: 'kept',
    );

    const result = LocalModelPerformanceModelResult(
      modelId: 'perf',
      catalogModelId: 'perf',
      displayName: 'Perf',
      samples: <LocalModelPerformanceSample>[
        LocalModelPerformanceSample(
          phase: LocalModelPerformancePhase.cold,
          repetition: 1,
          result: sample,
        ),
        LocalModelPerformanceSample(
          phase: LocalModelPerformancePhase.warm,
          repetition: 1,
          result: sample,
        ),
      ],
    );

    expect(result.coldSessionConfirmed, isFalse);
    expect(result.warmSessionConfirmed, isFalse);
    expect(LocalBenchmarkScoring.performanceScore(result), 0);
  });

  test('missing warm prefill telemetry is not rewarded as perfect', () {
    const cold = LocalModelBenchmarkCaseResult(
      caseId: 'performance_generation',
      response: 'benchmark response',
      score: 0,
      maxScore: 0,
      forbiddenHits: 0,
      firstContentMs: 1500,
      totalMs: 3500,
      reportedTokens: 40,
      prefillMs: 400,
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
    const warm = LocalModelBenchmarkCaseResult(
      caseId: 'performance_generation',
      response: 'benchmark response',
      score: 0,
      maxScore: 0,
      forbiddenHits: 0,
      firstContentMs: 750,
      totalMs: 2750,
      reportedTokens: 40,
      prefillMs: -1,
      observedGpuLayers: 33,
      observedBatch: 128,
      observedMicroBatch: 32,
      startPressure: 'normal',
      endPressure: 'normal',
      startAvailableBytes: 900,
      endAvailableBytes: 850,
      startBatteryTemperatureDeciC: 305,
      endBatteryTemperatureDeciC: 308,
      sessionStart: 'warm',
      sessionEnd: 'kept',
    );

    const result = LocalModelPerformanceModelResult(
      modelId: 'perf',
      catalogModelId: 'perf',
      displayName: 'Perf',
      samples: <LocalModelPerformanceSample>[
        LocalModelPerformanceSample(
          phase: LocalModelPerformancePhase.cold,
          repetition: 1,
          result: cold,
        ),
        LocalModelPerformanceSample(
          phase: LocalModelPerformancePhase.warm,
          repetition: 1,
          result: warm,
        ),
      ],
    );

    expect(LocalBenchmarkScoring.performanceScore(result), 80);
  });

  test('thermal score rewards low rise and stable performance', () {
    LocalModelBenchmarkCaseResult sample(int endTemp) =>
        LocalModelBenchmarkCaseResult(
          caseId: 'performance_generation',
          response: 'benchmark response',
          score: 0,
          maxScore: 0,
          forbiddenHits: 0,
          firstContentMs: 1000,
          totalMs: 3000,
          reportedTokens: 40,
          prefillMs: 400,
          observedGpuLayers: 33,
          observedBatch: 128,
          observedMicroBatch: 32,
          startPressure: 'normal',
          endPressure: 'normal',
          startAvailableBytes: 1000,
          endAvailableBytes: 900,
          startBatteryTemperatureDeciC: 300,
          endBatteryTemperatureDeciC: endTemp,
          sessionStart: 'warm',
          sessionEnd: 'kept',
        );

    final result = LocalModelThermalModelResult(
      modelId: 'thermal',
      catalogModelId: 'thermal',
      displayName: 'Thermal',
      baselineBatteryTemperatureDeciC: 300,
      samples: <LocalModelThermalSample>[
        LocalModelThermalSample(repetition: 1, result: sample(305)),
        LocalModelThermalSample(repetition: 2, result: sample(310)),
        LocalModelThermalSample(repetition: 3, result: sample(315)),
      ],
      stoppedEarly: false,
    );

    expect(LocalBenchmarkScoring.thermalScore(result), 100);
  });

  test('thermal score is absent after safety cutoff or missing temperature', () {
    const baseResult = LocalModelBenchmarkCaseResult(
      caseId: 'performance_generation',
      response: 'benchmark response',
      score: 0,
      maxScore: 0,
      forbiddenHits: 0,
      firstContentMs: 1000,
      totalMs: 3000,
      reportedTokens: 40,
      prefillMs: 400,
      observedGpuLayers: 33,
      observedBatch: 128,
      observedMicroBatch: 32,
      startPressure: 'normal',
      endPressure: 'normal',
      startAvailableBytes: 1000,
      endAvailableBytes: 900,
      startBatteryTemperatureDeciC: 300,
      endBatteryTemperatureDeciC: 320,
      sessionStart: 'warm',
      sessionEnd: 'kept',
    );

    const stopped = LocalModelThermalModelResult(
      modelId: 'thermal',
      catalogModelId: 'thermal',
      displayName: 'Thermal',
      baselineBatteryTemperatureDeciC: 300,
      samples: <LocalModelThermalSample>[
        LocalModelThermalSample(repetition: 1, result: baseResult),
      ],
      stoppedEarly: true,
      stopReason: 'temperature_cutoff',
    );
    const missing = LocalModelThermalModelResult(
      modelId: 'thermal',
      catalogModelId: 'thermal',
      displayName: 'Thermal',
      baselineBatteryTemperatureDeciC: null,
      samples: <LocalModelThermalSample>[
        LocalModelThermalSample(repetition: 1, result: baseResult),
      ],
      stoppedEarly: false,
    );

    expect(LocalBenchmarkScoring.thermalScore(stopped), isNull);
    expect(LocalBenchmarkScoring.thermalScore(missing), isNull);
  });

  test('memory context score combines recall, recovery and pressure', () {
    LocalModelBenchmarkCaseResult sample({
      required String id,
      required int score,
      String pressure = 'normal',
    }) =>
        LocalModelBenchmarkCaseResult(
          caseId: id,
          response: 'ok',
          score: score,
          maxScore: 1,
          forbiddenHits: 0,
          firstContentMs: 1200,
          totalMs: 3000,
          reportedTokens: 8,
          prefillMs: 700,
          observedGpuLayers: 33,
          observedBatch: 128,
          observedMicroBatch: 32,
          observedContext: 2048,
          startPressure: pressure,
          endPressure: pressure,
          startAvailableBytes: 2000,
          endAvailableBytes: 1700,
          startBatteryTemperatureDeciC: 320,
          endBatteryTemperatureDeciC: 325,
          sessionStart: 'warm',
          sessionEnd: 'kept',
        );

    LocalModelMemoryContextSample contextSample(
      String id, {
      required int score,
      String pressure = 'normal',
    }) =>
        LocalModelMemoryContextSample(
          levelId: id,
          targetCharacters: 3600,
          recovery: false,
          result: sample(id: id, score: score, pressure: pressure),
        );

    final perfect = LocalModelMemoryContextModelResult(
      modelId: model.effectiveRuntimeModelId,
      catalogModelId: model.id,
      displayName: model.displayName,
      samples: <LocalModelMemoryContextSample>[
        contextSample('l1', score: 1),
        contextSample('l2', score: 1),
        contextSample('l3', score: 1),
        contextSample('l4', score: 1),
        LocalModelMemoryContextSample(
          levelId: 'recovery',
          targetCharacters: 0,
          recovery: true,
          result: sample(id: 'recovery', score: 1),
        ),
      ],
      stoppedEarly: false,
    );

    final pressured = LocalModelMemoryContextModelResult(
      modelId: model.effectiveRuntimeModelId,
      catalogModelId: model.id,
      displayName: model.displayName,
      samples: <LocalModelMemoryContextSample>[
        contextSample('l1', score: 1, pressure: 'high'),
        contextSample('l2', score: 1, pressure: 'high'),
        contextSample('l3', score: 1, pressure: 'high'),
        contextSample('l4', score: 0, pressure: 'high'),
        LocalModelMemoryContextSample(
          levelId: 'recovery',
          targetCharacters: 0,
          recovery: true,
          result: sample(id: 'recovery', score: 1, pressure: 'high'),
        ),
      ],
      stoppedEarly: false,
    );

    expect(LocalBenchmarkScoring.memoryContextScore(perfect), 100);
    expect(LocalBenchmarkScoring.memoryContextScore(pressured), 75);
  });

  test('unknown memory pressure is not rewarded', () {
    const result = LocalModelMemoryContextModelResult(
      modelId: 'memory',
      catalogModelId: 'memory',
      displayName: 'Memory',
      samples: <LocalModelMemoryContextSample>[],
      stoppedEarly: true,
      stopReason: 'no telemetry',
    );

    expect(LocalBenchmarkScoring.memoryContextScore(result), 0);
  });

  test('score store persists matching model fingerprint', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = storeFor(preferences);

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
    final store = storeFor(preferences);

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

  test('score store ignores scores from a different hardware profile',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );

    final s24 = storeFor(
      preferences,
      hardwareProfile: 'android|s24fe-test',
    );
    await s24.saveComponent(
      model: model,
      component: LocalBenchmarkComponent.performance,
      score: 91,
      updatedAt: DateTime.utc(2026, 9, 30),
    );

    final redmi = storeFor(
      preferences,
      hardwareProfile: 'android|redmi-test',
    );
    final wrongDevice = await redmi.loadForModels(const <AiModel>[model]);
    expect(wrongDevice.containsKey(model.id), isFalse);

    final sameDevice = await s24.loadForModels(const <AiModel>[model]);
    expect(
      sameDevice[model.id]
          ?.components[LocalBenchmarkComponent.performance]
          ?.score,
      91,
    );
  });

  test('general score averages only completed benchmark suites', () {
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

    // The General Score is the transparent mean of completed suites.
    expect(score.generalScore, 90);
    expect(score.completedComponents, 2);
  });
}
