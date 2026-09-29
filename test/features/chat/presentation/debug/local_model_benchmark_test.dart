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
