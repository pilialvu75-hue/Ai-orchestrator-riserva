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

  test('unknown memory pressure does not produce a General Score', () {
    const result = LocalModelMemoryContextModelResult(
      modelId: 'memory',
      catalogModelId: 'memory',
      displayName: 'Memory',
      samples: <LocalModelMemoryContextSample>[],
      stoppedEarly: true,
      stopReason: 'no telemetry',
    );

    expect(LocalBenchmarkScoring.memoryContextScore(result), isNull);
  });

  test('multilingual score averages four equal language subscores', () {
    LocalModelBenchmarkCaseResult item(
      String id, {
      required int score,
    }) =>
        LocalModelBenchmarkCaseResult(
          caseId: id,
          response: 'ok',
          score: score,
          maxScore: 1,
          forbiddenHits: 0,
          firstContentMs: 1000,
          totalMs: 2000,
          reportedTokens: 8,
          prefillMs: 500,
          observedGpuLayers: 33,
          observedBatch: 128,
          observedMicroBatch: 32,
          observedContext: 2048,
          startPressure: 'normal',
          endPressure: 'normal',
          startAvailableBytes: 2000,
          endAvailableBytes: 1700,
          startBatteryTemperatureDeciC: 320,
          endBatteryTemperatureDeciC: 325,
          sessionStart: 'warm',
          sessionEnd: 'kept',
        );

    final result = LocalModelBenchmarkModelResult(
      modelId: model.effectiveRuntimeModelId,
      catalogModelId: model.id,
      displayName: model.displayName,
      cases: <LocalModelBenchmarkCaseResult>[
        item('multilingual_it_exact', score: 1),
        item('multilingual_it_fact', score: 1),
        item('multilingual_en_exact', score: 1),
        item('multilingual_en_fact', score: 0),
        item('multilingual_fr_exact', score: 1),
        item('multilingual_fr_fact', score: 1),
        item('multilingual_es_exact', score: 0),
        item('multilingual_es_fact', score: 0),
      ],
    );

    expect(
      LocalBenchmarkScoring.multilingualLanguageScore(result, 'it'),
      100,
    );
    expect(
      LocalBenchmarkScoring.multilingualLanguageScore(result, 'en'),
      50,
    );
    expect(
      LocalBenchmarkScoring.multilingualLanguageScore(result, 'fr'),
      100,
    );
    expect(
      LocalBenchmarkScoring.multilingualLanguageScore(result, 'es'),
      0,
    );
    expect(LocalBenchmarkScoring.multilingualScore(result), 63);
  });

  test('multilingual score is invalid when a language is missing', () {
    final result = LocalModelBenchmarkModelResult(
      modelId: model.effectiveRuntimeModelId,
      catalogModelId: model.id,
      displayName: model.displayName,
      cases: <LocalModelBenchmarkCaseResult>[
        perfectCase(),
      ],
    );

    expect(LocalBenchmarkScoring.multilingualScore(result), isNull);
  });

  test('stability score rewards complete consecutive and recovery probes', () {
    LocalModelBenchmarkCaseResult sample({
      required int index,
      int score = 1,
      String pressure = 'normal',
    }) =>
        LocalModelBenchmarkCaseResult(
          caseId: 'stability_$index',
          response: 'STABLE-OK',
          score: score,
          maxScore: 1,
          forbiddenHits: 0,
          firstContentMs: 900,
          totalMs: 1400,
          reportedTokens: 4,
          prefillMs: 350,
          observedGpuLayers: 33,
          observedBatch: 128,
          observedMicroBatch: 32,
          startPressure: pressure,
          endPressure: pressure,
          startAvailableBytes: 2000,
          endAvailableBytes: 1800,
          startBatteryTemperatureDeciC: 320,
          endBatteryTemperatureDeciC: 325,
          sessionStart: index == 0 ? 'cold' : 'warm',
          sessionEnd: 'kept',
        );

    final perfect = LocalModelStabilityModelResult(
      modelId: model.effectiveRuntimeModelId,
      catalogModelId: model.id,
      displayName: model.displayName,
      consecutiveSamples: <LocalModelBenchmarkCaseResult>[
        for (var i = 0;
            i < LocalModelBenchmarkRunner.stabilityConsecutiveRepetitions;
            i++)
          sample(index: i),
      ],
      sessionReuseConfirmed: true,
      cancellationConfirmed: true,
      cancellationRecoveryPassed: true,
      switchRecoveryPassed: true,
      switchPartnerModelId: 'partner',
    );

    final degraded = LocalModelStabilityModelResult(
      modelId: model.effectiveRuntimeModelId,
      catalogModelId: model.id,
      displayName: model.displayName,
      consecutiveSamples: <LocalModelBenchmarkCaseResult>[
        sample(index: 0),
        sample(index: 1),
        sample(index: 2),
        sample(index: 3),
        sample(index: 4, score: 0),
      ],
      sessionReuseConfirmed: true,
      cancellationConfirmed: false,
      cancellationRecoveryPassed: true,
      switchRecoveryPassed: true,
      switchPartnerModelId: 'partner',
    );

    expect(perfect.probeSetComplete, isTrue);
    expect(LocalBenchmarkScoring.stabilityScore(perfect), 100);
    expect(LocalBenchmarkScoring.stabilityScore(degraded), 77);
  });

  test('incomplete or critical stability run is not persisted as a score', () {
    const incomplete = LocalModelStabilityModelResult(
      modelId: 'stable',
      catalogModelId: 'stable',
      displayName: 'Stable',
      consecutiveSamples: <LocalModelBenchmarkCaseResult>[],
      sessionReuseConfirmed: null,
      cancellationConfirmed: null,
      cancellationRecoveryPassed: null,
      switchRecoveryPassed: null,
      switchPartnerModelId: null,
    );

    final criticalSample = LocalModelBenchmarkCaseResult(
      caseId: 'stability',
      response: 'STABLE-OK',
      score: 1,
      maxScore: 1,
      forbiddenHits: 0,
      firstContentMs: 900,
      totalMs: 1400,
      reportedTokens: 4,
      prefillMs: 350,
      observedGpuLayers: 33,
      observedBatch: 128,
      observedMicroBatch: 32,
      startPressure: 'critical',
      endPressure: 'critical',
      startAvailableBytes: 300,
      endAvailableBytes: 200,
      startBatteryTemperatureDeciC: 330,
      endBatteryTemperatureDeciC: 335,
      sessionStart: 'warm',
      sessionEnd: 'kept',
    );
    final critical = LocalModelStabilityModelResult(
      modelId: 'stable',
      catalogModelId: 'stable',
      displayName: 'Stable',
      consecutiveSamples: <LocalModelBenchmarkCaseResult>[
        for (var i = 0;
            i < LocalModelBenchmarkRunner.stabilityConsecutiveRepetitions;
            i++)
          criticalSample,
      ],
      sessionReuseConfirmed: true,
      cancellationConfirmed: true,
      cancellationRecoveryPassed: true,
      switchRecoveryPassed: true,
      switchPartnerModelId: 'partner',
    );

    expect(incomplete.probeSetComplete, isFalse);
    expect(LocalBenchmarkScoring.stabilityScore(incomplete), isNull);
    expect(LocalBenchmarkScoring.stabilityScore(critical), isNull);
  });

  test('Orchestrator role score requires the complete current suite', () {
    LocalModelBenchmarkCaseResult resultFor(
      LocalModelBenchmarkCase benchmarkCase, {
      bool pass = true,
    }) =>
        LocalModelBenchmarkCaseResult(
          caseId: benchmarkCase.id,
          response: pass ? 'pass' : 'fail',
          score: pass ? benchmarkCase.maxScore : 0,
          maxScore: benchmarkCase.maxScore,
          forbiddenHits: 0,
          firstContentMs: 1000,
          totalMs: 2000,
          reportedTokens: 8,
          prefillMs: 500,
          observedGpuLayers: 33,
          observedBatch: 128,
          observedMicroBatch: 32,
          startPressure: 'normal',
          endPressure: 'normal',
          startAvailableBytes: 2000,
          endAvailableBytes: 1800,
          startBatteryTemperatureDeciC: 320,
          endBatteryTemperatureDeciC: 325,
          sessionStart: 'warm',
          sessionEnd: 'kept',
        );

    final perfect = LocalModelBenchmarkModelResult(
      modelId: model.effectiveRuntimeModelId,
      catalogModelId: model.id,
      displayName: model.displayName,
      cases: <LocalModelBenchmarkCaseResult>[
        for (final benchmarkCase in LocalModelBenchmarkRunner.cases)
          resultFor(benchmarkCase),
      ],
    );

    final incomplete = LocalModelBenchmarkModelResult(
      modelId: model.effectiveRuntimeModelId,
      catalogModelId: model.id,
      displayName: model.displayName,
      cases: <LocalModelBenchmarkCaseResult>[
        resultFor(LocalModelBenchmarkRunner.cases.first),
      ],
    );

    expect(LocalBenchmarkScoring.orchestratorRoleScore(perfect), 100);
    expect(LocalBenchmarkScoring.orchestratorRoleScore(incomplete), isNull);
  });

  test('Orchestrator role score is persisted separately from General Score',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = storeFor(preferences);

    await store.saveComponent(
      model: model,
      component: LocalBenchmarkComponent.quick,
      score: 80,
      updatedAt: DateTime.utc(2026, 9, 30, 1),
    );
    await store.saveRoleScore(
      model: model,
      role: LocalBenchmarkRole.orchestrator,
      score: 92,
      updatedAt: DateTime.utc(2026, 9, 30, 2),
    );

    final loaded = await store.loadForModels(const <AiModel>[model]);
    final score = loaded[model.id];

    expect(score?.generalScore, 80);
    expect(score?.completedComponents, 1);
    expect(score?.roleScore(LocalBenchmarkRole.orchestrator), 92);

    await store.saveComponent(
      model: model,
      component: LocalBenchmarkComponent.quality,
      score: 60,
      updatedAt: DateTime.utc(2026, 9, 30, 3),
    );

    final reloaded = await store.loadForModels(const <AiModel>[model]);
    expect(reloaded[model.id]?.generalScore, 70);
    expect(
      reloaded[model.id]?.roleScore(LocalBenchmarkRole.orchestrator),
      92,
    );
  });

  test('Vulkan score is neutral when GPU matches CPU performance', () {
    LocalModelBenchmarkCaseResult result({
      required int observed,
    }) =>
        LocalModelBenchmarkCaseResult(
          caseId: 'vulkan_fact',
          response: 'Vulkan API Khronos',
          score: 2,
          maxScore: 2,
          forbiddenHits: 0,
          firstContentMs: 1000,
          totalMs: 5000,
          reportedTokens: 40,
          prefillMs: 800,
          observedGpuLayers: observed,
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

    final samples = <VulkanLayerSweepSample>[
      for (final repetition in <int>[1, 2]) ...<VulkanLayerSweepSample>[
        VulkanLayerSweepSample(
          requestedGpuLayers: 0,
          modelId: model.effectiveRuntimeModelId,
          catalogModelId: model.id,
          displayName: model.displayName,
          repetition: repetition,
          result: result(observed: 0),
        ),
        VulkanLayerSweepSample(
          requestedGpuLayers: 10,
          modelId: model.effectiveRuntimeModelId,
          catalogModelId: model.id,
          displayName: model.displayName,
          repetition: repetition,
          result: result(observed: 10),
        ),
      ],
    ];

    final score = LocalBenchmarkScoring.vulkanScore(
      VulkanLayerSweepReport(
        createdAt: DateTime.utc(2026, 9, 30),
        samples: samples,
      ),
      model.id,
    );

    expect(score, isNotNull);
    expect(score!.score, 50);
    expect(score.bestRequestedGpuLayers, 10);
    expect(score.averageObservedGpuLayers, 10);
  });

  test('Vulkan score reaches 100 for a complete 2x GPU acceleration', () {
    LocalModelBenchmarkCaseResult result({
      required int firstMs,
      required int totalMs,
      required int prefillMs,
      required int tokens,
      required int observed,
    }) =>
        LocalModelBenchmarkCaseResult(
          caseId: 'vulkan_fact',
          response: 'Vulkan API Khronos',
          score: 2,
          maxScore: 2,
          forbiddenHits: 0,
          firstContentMs: firstMs,
          totalMs: totalMs,
          reportedTokens: tokens,
          prefillMs: prefillMs,
          observedGpuLayers: observed,
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

    final samples = <VulkanLayerSweepSample>[
      for (final repetition in <int>[1, 2]) ...<VulkanLayerSweepSample>[
        VulkanLayerSweepSample(
          requestedGpuLayers: 0,
          modelId: model.effectiveRuntimeModelId,
          catalogModelId: model.id,
          displayName: model.displayName,
          repetition: repetition,
          result: result(
            firstMs: 2000,
            totalMs: 6000,
            prefillMs: 800,
            tokens: 40,
            observed: 0,
          ),
        ),
        VulkanLayerSweepSample(
          requestedGpuLayers: 99,
          modelId: model.effectiveRuntimeModelId,
          catalogModelId: model.id,
          displayName: model.displayName,
          repetition: repetition,
          result: result(
            firstMs: 1000,
            totalMs: 3000,
            prefillMs: 400,
            tokens: 40,
            observed: 33,
          ),
        ),
      ],
    ];

    final score = LocalBenchmarkScoring.vulkanScore(
      VulkanLayerSweepReport(
        createdAt: DateTime.utc(2026, 9, 30),
        samples: samples,
      ),
      model.id,
    );

    expect(score, isNotNull);
    expect(score!.score, 100);
    expect(score.bestRequestedGpuLayers, 99);
    expect(score.averageObservedGpuLayers, 33);
  });

  test('Vulkan score is absent when GPU repetitions are incomplete', () {
    const cpu = LocalModelBenchmarkCaseResult(
      caseId: 'vulkan_fact',
      response: 'Vulkan API Khronos',
      score: 2,
      maxScore: 2,
      forbiddenHits: 0,
      firstContentMs: 1000,
      totalMs: 5000,
      reportedTokens: 40,
      prefillMs: 800,
      observedGpuLayers: 0,
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
    const gpu = LocalModelBenchmarkCaseResult(
      caseId: 'vulkan_fact',
      response: 'Vulkan API Khronos',
      score: 2,
      maxScore: 2,
      forbiddenHits: 0,
      firstContentMs: 800,
      totalMs: 4000,
      reportedTokens: 40,
      prefillMs: 600,
      observedGpuLayers: 10,
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

    final score = LocalBenchmarkScoring.vulkanScore(
      VulkanLayerSweepReport(
        createdAt: DateTime.utc(2026, 9, 30),
        samples: <VulkanLayerSweepSample>[
          for (final repetition in <int>[1, 2])
            VulkanLayerSweepSample(
              requestedGpuLayers: 0,
              modelId: model.effectiveRuntimeModelId,
              catalogModelId: model.id,
              displayName: model.displayName,
              repetition: repetition,
              result: cpu,
            ),
          VulkanLayerSweepSample(
            requestedGpuLayers: 10,
            modelId: model.effectiveRuntimeModelId,
            catalogModelId: model.id,
            displayName: model.displayName,
            repetition: 1,
            result: gpu,
          ),
        ],
      ),
      model.id,
    );

    expect(score, isNull);
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

  test('General Score ranking prefers score then suite completeness', () {
    AiModel candidate(String id, String name) => AiModel(
          id: id,
          displayName: name,
          fileName: '$id.gguf',
          downloadUrl: '',
          version: '1.0.0',
          sizeBytes: 2048,
          description: 'benchmark candidate',
          isDownloaded: true,
          localPath: '/models/$id.gguf',
          validationStatus: ModelValidationStatus.validatedOk,
        );

    LocalModelBenchmarkScore scoreFor(
      AiModel candidate,
      int score,
      int components,
    ) {
      final entries = <LocalBenchmarkComponent, LocalBenchmarkComponentScore>{};
      for (final component
          in LocalBenchmarkComponent.values.take(components)) {
        entries[component] = LocalBenchmarkComponentScore(
          score: score,
          updatedAt: DateTime.utc(2026, 9, 30),
        );
      }
      return LocalModelBenchmarkScore(
        modelId: candidate.id,
        fingerprint: LocalBenchmarkScoreStore.fingerprintFor(candidate),
        components: entries,
      );
    }

    final alpha = candidate('alpha', 'Alpha');
    final beta = candidate('beta', 'Beta');
    final gamma = candidate('gamma', 'Gamma');
    final unscored = candidate('unscored', 'Unscored');

    final scores = <String, LocalModelBenchmarkScore>{
      alpha.id: scoreFor(alpha, 80, 8),
      beta.id: scoreFor(beta, 90, 2),
      gamma.id: scoreFor(gamma, 90, 6),
    };

    final ranked = LocalBenchmarkScoring.rankModelsByGeneralScore(
      <AiModel>[unscored, alpha, beta, gamma],
      scores,
    );

    expect(
      ranked.map((item) => item.id).toList(),
      <String>['gamma', 'beta', 'alpha', 'unscored'],
    );
  });

  test('Top General selection excludes unscored and ineligible models', () {
    AiModel candidate(
      String id,
      String name, {
      bool downloaded = true,
    }) =>
        AiModel(
          id: id,
          displayName: name,
          fileName: '$id.gguf',
          downloadUrl: '',
          version: '1.0.0',
          sizeBytes: 2048,
          description: 'benchmark candidate',
          isDownloaded: downloaded,
          localPath: downloaded ? '/models/$id.gguf' : null,
          validationStatus: downloaded
              ? ModelValidationStatus.validatedOk
              : ModelValidationStatus.notDownloaded,
        );

    LocalModelBenchmarkScore scoreFor(AiModel candidate, int score) =>
        LocalModelBenchmarkScore(
          modelId: candidate.id,
          fingerprint: LocalBenchmarkScoreStore.fingerprintFor(candidate),
          components: <LocalBenchmarkComponent, LocalBenchmarkComponentScore>{
            LocalBenchmarkComponent.quick: LocalBenchmarkComponentScore(
              score: score,
              updatedAt: DateTime.utc(2026, 9, 30),
            ),
          },
        );

    final bestButUnavailable =
        candidate('offline', 'Offline', downloaded: false);
    final first = candidate('first', 'First');
    final second = candidate('second', 'Second');
    final unscored = candidate('unscored', 'Unscored');

    final scores = <String, LocalModelBenchmarkScore>{
      bestButUnavailable.id: scoreFor(bestButUnavailable, 99),
      first.id: scoreFor(first, 92),
      second.id: scoreFor(second, 88),
    };

    expect(
      LocalBenchmarkScoring.topGeneralModelIds(
        <AiModel>[bestButUnavailable, second, unscored, first],
        scores,
        limit: 3,
        isEligible: (candidate) => candidate.isDownloaded,
      ),
      <String>['first', 'second'],
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
