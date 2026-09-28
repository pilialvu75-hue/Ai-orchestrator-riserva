import 'package:ai_orchestrator/features/chat/presentation/debug/local_model_benchmark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('Vulkan matrix has CPU, moderate and full-offload requests', () {
    expect(
      LocalModelBenchmarkRunner.vulkanMatrixGpuLayers,
      <int>[0, 10, 50],
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
      prefillMs: 40,
      totalMs: 200,
      reportedTokens: 10,
      observedGpuLayers: 33,
      observedBatch: 128,
      observedMicroBatch: 32,
      startPressure: 'normal',
      endPressure: 'high',
      startAvailableBytes: 1000,
      endAvailableBytes: 500,
      startBatteryTemperatureMilliC: 32000,
      endBatteryTemperatureMilliC: 33500,
      sessionStart: 'warm',
      sessionEnd: 'released',
    );
    final report = LocalModelBenchmarkReport(
      createdAt: DateTime.utc(2026, 9, 25),
      models: const <LocalModelBenchmarkModelResult>[
        LocalModelBenchmarkModelResult(
          modelId: 'phi3_5_mini',
          displayName: 'Phi',
          requestedGpuLayers: 50,
          cases: <LocalModelBenchmarkCaseResult>[item],
        ),
      ],
    );

    final diagnosticsText = report.toPlainText(includeResponses: false);
    expect(diagnosticsText, contains('quality=1/1'));
    expect(diagnosticsText, contains('gpu_request=50'));
    expect(diagnosticsText, contains('prefill=40ms'));
    expect(diagnosticsText, contains('battery_temp_c=32.0->33.5'));
    expect(diagnosticsText, contains('session=warm->released'));
    expect(diagnosticsText, isNot(contains('private response text')));
  });
}
