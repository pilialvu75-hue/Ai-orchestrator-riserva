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

  test('thermal stress keeps bounded repetitions and 45C safety stop', () {
    expect(LocalModelBenchmarkRunner.thermalStressRepetitions, 10);
    expect(LocalModelBenchmarkRunner.thermalStressStopDeciC, 450);
  });

  test('thermal result derives peak, rise and pressure counts', () {
    const first = LocalModelBenchmarkCaseResult(
      caseId: 'performance_generation',
      response: 'ok',
      score: 0,
      maxScore: 0,
      forbiddenHits: 0,
      firstContentMs: 1000,
      totalMs: 4000,
      reportedTokens: 40,
      prefillMs: 500,
      observedGpuLayers: 33,
      observedBatch: 128,
      observedMicroBatch: 32,
      startPressure: 'normal',
      endPressure: 'normal',
      startAvailableBytes: 1000,
      endAvailableBytes: 900,
      startBatteryTemperatureDeciC: 320,
      endBatteryTemperatureDeciC: 335,
      sessionStart: 'cold',
      sessionEnd: 'kept',
    );
    const second = LocalModelBenchmarkCaseResult(
      caseId: 'performance_generation',
      response: 'ok',
      score: 0,
      maxScore: 0,
      forbiddenHits: 0,
      firstContentMs: 800,
      totalMs: 3500,
      reportedTokens: 40,
      prefillMs: 400,
      observedGpuLayers: 33,
      observedBatch: 128,
      observedMicroBatch: 32,
      startPressure: 'normal',
      endPressure: 'high',
      startAvailableBytes: 900,
      endAvailableBytes: 700,
      startBatteryTemperatureDeciC: 335,
      endBatteryTemperatureDeciC: 350,
      sessionStart: 'warm',
      sessionEnd: 'kept',
    );

    const result = LocalModelThermalStressResult(
      modelId: 'model',
      catalogModelId: 'model',
      displayName: 'Model',
      samples: <LocalModelBenchmarkCaseResult>[first, second],
      targetRepetitions: 10,
      thermalLimitReached: false,
      criticalResourceStop: false,
    );

    expect(result.startBatteryTemperatureC, 32.0);
    expect(result.maxBatteryTemperatureC, 35.0);
    expect(result.batteryTemperatureRiseC, 3.0);
    expect(result.pressuredSamples, 1);
    expect(result.hasValidThermalTelemetry, isTrue);
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
