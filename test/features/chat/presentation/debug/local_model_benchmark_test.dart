import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/local_model_benchmark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('orchestrator benchmark keeps Phi and Nemotron defaults', () {
    expect(
      LocalModelBenchmarkRunner.defaultOrchestratorTargetModelIds,
      const <String>[
        LocalInferenceModelIds.phi35Mini,
        LocalInferenceModelIds.nemotron3Nano4b,
      ],
    );
  });

  test('benchmark candidate must be downloaded, validated and have a path', () {
    const base = AiModel(
      id: 'candidate',
      displayName: 'Candidate',
      fileName: 'candidate.gguf',
      downloadUrl: '',
      version: '1',
      sizeBytes: 123,
      description: 'test',
      isDownloaded: true,
      localPath: '/models/candidate.gguf',
      validationStatus: ModelValidationStatus.validatedOk,
    );

    expect(LocalModelBenchmarkRunner.isRunnableCandidate(base), isTrue);
    expect(
      LocalModelBenchmarkRunner.isRunnableCandidate(
        base.copyWith(
          validationStatus: ModelValidationStatus.updateAvailable,
        ),
      ),
      isTrue,
    );
    expect(
      LocalModelBenchmarkRunner.isRunnableCandidate(
        base.copyWith(isDownloaded: false),
      ),
      isFalse,
    );
    expect(
      LocalModelBenchmarkRunner.isRunnableCandidate(
        base.copyWith(localPath: ''),
      ),
      isFalse,
    );
    expect(
      LocalModelBenchmarkRunner.isRunnableCandidate(
        base.copyWith(
          validationStatus: ModelValidationStatus.invalidModel,
        ),
      ),
      isFalse,
    );
  });

  test('quick benchmark keeps the intended small representative suite', () {
    expect(
      LocalModelBenchmarkRunner.quickCases.map((item) => item.id).toSet(),
      <String>{
        'vulkan_fact',
        'ram_fact',
        'arithmetic',
        'ssd_hdd_followup',
      },
    );
  });

  test('quality suite is separate and covers seven general quality cases', () {
    expect(
      LocalModelBenchmarkRunner.qualityCases.map((item) => item.id).toSet(),
      <String>{
        'quality_fact_planet',
        'quality_fact_water',
        'quality_instruction_arithmetic',
        'quality_context_license',
        'quality_hallucination_unknown',
        'quality_logic_deduction',
        'quality_exact_instruction',
      },
    );
  });

  test('exact-answer rubric rewards instruction following only when exact', () {
    const benchmarkCase = LocalModelBenchmarkCase(
      id: 'exact',
      prompt: 'Rispondi solo con 42',
      requiredAnyGroups: <List<String>>[
        <String>['42'],
      ],
      exactAnswers: <String>['42'],
    );

    expect(benchmarkCase.maxScore, 2);
    expect(benchmarkCase.score('42'), 2);
    expect(benchmarkCase.score('42.'), 2);
    expect(benchmarkCase.score('La risposta è 42'), 1);
  });

  test('performance benchmark uses one cold and two warm passes', () {
    expect(LocalModelBenchmarkRunner.performanceWarmRepetitions, 2);
    expect(
      LocalModelBenchmarkRunner.performanceCase.id,
      'performance_generation',
    );
    expect(LocalModelBenchmarkRunner.performanceCase.maxScore, 0);
  });

  test('thermal stress keeps conservative safety profile', () {
    expect(LocalModelBenchmarkRunner.thermalStressRepetitions, 10);
    expect(
      LocalModelBenchmarkRunner.thermalStartMaxBatteryTemperatureDeciC,
      420,
    );
    expect(
      LocalModelBenchmarkRunner.thermalStopBatteryTemperatureDeciC,
      450,
    );
    expect(LocalModelBenchmarkRunner.thermalMaxRiseDeciC, 80);
  });

  test('thermal result derives rise and performance retention', () {
    LocalModelBenchmarkCaseResult sample({
      required int firstMs,
      required int endTemp,
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
        LocalModelThermalSample(
          repetition: 1,
          result: sample(firstMs: 1000, endTemp: 305),
        ),
        LocalModelThermalSample(
          repetition: 2,
          result: sample(firstMs: 1050, endTemp: 310),
        ),
        LocalModelThermalSample(
          repetition: 3,
          result: sample(firstMs: 1100, endTemp: 315),
        ),
      ],
      stoppedEarly: false,
    );

    expect(result.thermalTelemetryComplete, isTrue);
    expect(result.batteryTemperatureRiseC, 1.5);
    expect(result.decodeRetention, closeTo(1.0, 0.001));
    expect(result.firstContentSlowdown, closeTo(1.0, 0.1));
  });

  test('Vulkan rubric rewards API/Khronos and penalizes hallucinations', () {
    final benchmarkCase = LocalModelBenchmarkRunner.cases
        .firstWhere((item) => item.id == 'vulkan_fact');

    expect(
      benchmarkCase.score(
        'Vulkan è una API grafica standardizzata dal Khronos Group.',
      ),
      2,
    );
    expect(
      benchmarkCase.score(
        'Vulkan è un linguaggio di programmazione progettato da Google.',
      ),
      0,
    );
    expect(
      benchmarkCase.forbiddenHits(
        'Vulkan è un linguaggio di programmazione progettato da Google.',
      ),
      2,
    );
  });

  test('SDD typo rubric distinguishes SSD inference from uncertainty', () {
    final benchmarkCase = LocalModelBenchmarkRunner.cases
        .firstWhere((item) => item.id == 'sdd_typo_first');

    expect(
      benchmarkCase.score(
        'Probabilmente intendi SSD, unità a stato solido.',
      ),
      1,
    );
    expect(
      benchmarkCase.score(
        'SDD non è un acronimo chiaro, serve più contesto.',
      ),
      0,
    );
  });

  test('RAM rubric accepts natural Italian memory wording', () {
    final benchmarkCase = LocalModelBenchmarkRunner.cases
        .firstWhere((item) => item.id == 'ram_fact');

    expect(
      benchmarkCase.score(
        'La RAM memorizza temporaneamente dati e istruzioni in uso.',
      ),
      2,
    );
  });

  test('report omits responses when requested', () {
    const item = LocalModelBenchmarkCaseResult(
      caseId: 'sample',
      response: 'private response text',
      score: 1,
      maxScore: 1,
      forbiddenHits: 0,
      firstContentMs: 100,
      totalMs: 200,
      reportedTokens: 10,
      prefillMs: 75,
      observedGpuLayers: 33,
      observedBatch: 128,
      observedMicroBatch: 32,
      startPressure: 'normal',
      endPressure: 'high',
      startAvailableBytes: 1000,
      endAvailableBytes: 500,
      startBatteryTemperatureDeciC: 350,
      endBatteryTemperatureDeciC: 365,
      sessionStart: 'warm',
      sessionEnd: 'released',
    );
    final report = LocalModelBenchmarkReport(
      createdAt: DateTime.utc(2026, 9, 25),
      models: const <LocalModelBenchmarkModelResult>[
        LocalModelBenchmarkModelResult(
          modelId: 'phi3_5_mini',
          displayName: 'Phi',
          cases: <LocalModelBenchmarkCaseResult>[item],
        ),
      ],
    );

    final diagnosticsText = report.toPlainText(includeResponses: false);
    expect(diagnosticsText, contains('quality=1/1'));
    expect(diagnosticsText, contains('prefill=75ms'));
    expect(diagnosticsText, contains('battery_temp_c=35.0->36.5'));
    expect(diagnosticsText, contains('session=warm->released'));
    expect(diagnosticsText, isNot(contains('private response text')));
  });
}
