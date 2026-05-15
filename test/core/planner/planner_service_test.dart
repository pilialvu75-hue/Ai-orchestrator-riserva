import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/planner/plan.dart';
import 'package:ai_orchestrator/core/planner/planner_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';

const _validModel = AiModel(
  id: 'gemma_2b',
  displayName: 'Gemma 2B',
  fileName: 'gemma.gguf',
  downloadUrl: 'https://example.com/model.gguf',
  version: '1.0.0',
  sizeBytes: 123,
  description: 'Test model',
  isDownloaded: true,
  localPath: '/tmp/gemma.gguf',
  validationStatus: ModelValidationStatus.validatedOk,
);

class _FakeLocalRuntime extends LocalRuntimeProvider {
  _FakeLocalRuntime(this._response);
  final String _response;

  @override
  bool supportsModel(AiModel model) => true;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    yield InferenceResponse.finalChunk(
      text: _response,
      tokensGenerated: 1,
      model: 'fake',
    );
  }
}

CloudRuntimeProvider _buildCloudProvider() => CloudRuntimeProvider(
      sendQuery: (_, __) async => throw const ServerFailure('cloud disabled'),
      supportedProviders: () => [],
      isProviderAvailable: (_) => false,
      providerDisplayName: ([_]) => '',
    );

InferenceService _buildInferenceService(String fakeResponse) {
  return InferenceService(
    loadSelectedModel: () async => _validModel,
    loadRuntimeMode: () async => AiRuntimeMode.local,
    runtimeProvider: _FakeLocalRuntime(fakeResponse),
    cloudRuntimeProvider: _buildCloudProvider(),
    sessionManager: RuntimeSessionManager(),
  );
}

void main() {
  group('PlannerService', () {
    test('parses numbered list into plan steps', () async {
      const llmResponse = '''
1. Understand the problem
2. Identify root cause
3. Write a fix
4. Verify the solution
''';
      final service = PlannerService(
        inferenceService: _buildInferenceService(llmResponse),
      );

      final plan = await service.decompose('Fix this bug');

      expect(plan.goal, 'Fix this bug');
      expect(plan.steps.length, 4);
      expect(plan.steps[0].description, 'Understand the problem');
      expect(plan.steps[1].description, 'Identify root cause');
      expect(plan.steps[2].description, 'Write a fix');
      expect(plan.steps[3].description, 'Verify the solution');
      expect(plan.status, PlanStatus.created);
    });

    test('accepts parenthesis-separated step numbers', () async {
      const llmResponse = '''
1) Step one
2) Step two
''';
      final service = PlannerService(
        inferenceService: _buildInferenceService(llmResponse),
      );

      final plan = await service.decompose('Do something');
      expect(plan.steps.length, 2);
      expect(plan.steps[0].description, 'Step one');
      expect(plan.steps[1].description, 'Step two');
    });

    test('returns fallback single-step plan when LLM emits no list', () async {
      final service = PlannerService(
        inferenceService:
            _buildInferenceService('Sure, I can help with that.'),
      );

      final plan = await service.decompose('Do something');

      expect(plan.steps.length, 1);
      expect(plan.steps[0].description, 'Do something');
    });

    test('returns fallback single-step plan when LLM emits empty text',
        () async {
      final service = PlannerService(
        inferenceService: _buildInferenceService(''),
      );

      final plan = await service.decompose('Goal with no LLM response');

      expect(plan.steps.length, 1);
      expect(plan.steps[0].description, 'Goal with no LLM response');
    });

    test('assigns sequential zero-based indices', () async {
      const llmResponse = '1. Alpha\n2. Beta\n3. Gamma';
      final service = PlannerService(
        inferenceService: _buildInferenceService(llmResponse),
      );

      final plan = await service.decompose('test');

      for (var i = 0; i < plan.steps.length; i++) {
        expect(plan.steps[i].index, i);
      }
    });

    test('plan id is non-empty', () async {
      final service = PlannerService(
        inferenceService: _buildInferenceService('1. Only step'),
      );
      final plan = await service.decompose('goal');
      expect(plan.id, isNotEmpty);
    });
  });
}
