import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

void main() {
  const validModel = AiModel(
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

  InferenceService buildService({
    required AiRuntimeMode mode,
    AiModel? selectedModel,
    required FakeLocalRuntimeProvider localRuntimeProvider,
    required CloudRuntimeProvider cloudRuntimeProvider,
  }) {
    return InferenceService(
      loadSelectedModel: () async => selectedModel,
      loadRuntimeMode: () async => mode,
      runtimeProvider: localRuntimeProvider,
      cloudRuntimeProvider: cloudRuntimeProvider,
    );
  }

  /// Builds a [CloudRuntimeProvider] suitable for testing.
  ///
  /// [configured] controls whether the provider reports itself as available.
  /// When [false] the cloud provider appears unconfigured and
  /// [InferenceService] falls back to local mode or reports an error.
  CloudRuntimeProvider buildCloudProvider({
    bool configured = true,
    Future<AiResponse> Function(String provider, AiRequest request)? sendQuery,
  }) {
    return CloudRuntimeProvider(
      sendQuery: sendQuery ??
          (_, __) async => AiResponse(
                text: 'Cloud response',
                model: 'gpt-4o',
                tokensUsed: 8,
                timestamp: DateTime.now().millisecondsSinceEpoch,
              ),
      supportedProviders: () => <String>['openAi'],
      isProviderAvailable: (_) => configured,
      providerDisplayName: ([providerName]) => 'OpenAI',
    );
  }

  group('InferenceService routing', () {
    test('returns error when cloud mode has no API key and no local model',
        () async {
      final service = buildService(
        mode: AiRuntimeMode.cloud,
        selectedModel: null,
        localRuntimeProvider: FakeLocalRuntimeProvider(),
        cloudRuntimeProvider: buildCloudProvider(configured: false),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 's1', prompt: 'hello'),
      );

      expect(response.isError, true);
      // When no provider is available and no local model exists, the
      // CloudRuntimeProvider emits its "fully local" notice as an error and
      // InferenceService propagates it.
      expect(response.errorMessage, CloudRuntimeProvider.fullyLocalNotice);
    });

    test('falls back to local when cloud mode is selected without API key',
        () async {
      var cloudCalls = 0;
      final service = buildService(
        mode: AiRuntimeMode.cloud,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          responses: <InferenceResponse>[
            InferenceResponse.finalChunk(
              text: 'Local response',
              tokensGenerated: 4,
              model: 'gemma_2b',
            ),
          ],
        ),
        cloudRuntimeProvider: buildCloudProvider(
          configured: false,
          sendQuery: (_, __) async {
            cloudCalls += 1;
            throw AssertionError('cloud should not be called');
          },
        ),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 's2', prompt: 'hello'),
      );

      expect(response.isError, false);
      expect(response.text, 'Local response');
      expect(response.model, 'gemma_2b');
      expect(cloudCalls, 0);
    });

    test('falls back to local when cloud authentication fails', () async {
      final service = buildService(
        mode: AiRuntimeMode.cloud,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          responses: <InferenceResponse>[
            InferenceResponse.finalChunk(
              text: 'Recovered locally',
              tokensGenerated: 6,
              model: 'gemma_2b',
            ),
          ],
        ),
        cloudRuntimeProvider: buildCloudProvider(
          sendQuery: (_, __) async => throw const ServerFailure(
            'OpenAI API error 401: invalid_api_key',
          ),
        ),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 's3', prompt: 'hello'),
      );

      expect(response.isError, false);
      expect(response.text, 'Recovered locally');
      expect(response.model, 'gemma_2b');
    });

    test('hybrid mode falls back to cloud when local startup fails', () async {
      final service = buildService(
        mode: AiRuntimeMode.hybrid,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          responses: <InferenceResponse>[
            InferenceResponse.error('Missing local model path.'),
          ],
        ),
        cloudRuntimeProvider: buildCloudProvider(),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 's4', prompt: 'hello'),
      );

      expect(response.isError, false);
      expect(response.text, 'Cloud response');
      expect(response.model, 'gpt-4o');
    });
  });
}

class FakeLocalRuntimeProvider extends LocalRuntimeProvider {
  FakeLocalRuntimeProvider({
    this.responses = const <InferenceResponse>[],
    this.isSupported = true,
  });

  final List<InferenceResponse> responses;
  final bool isSupported;

  @override
  bool supportsModel(AiModel model) => isSupported;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    for (final response in responses) {
      yield response;
    }
  }
}
