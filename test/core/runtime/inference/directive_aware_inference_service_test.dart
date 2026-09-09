import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/directive_aware_inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cloudOnly never falls back to the selected local model', () async {
    var selectedModelLoads = 0;
    var cloudCalls = 0;
    var localCalls = 0;

    const localModel = AiModel(
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

    final localProvider = _CountingLocalRuntimeProvider(
      onStream: () {
        localCalls += 1;
      },
    );

    final cloudProvider = CloudRuntimeProvider(
      sendQuery: (String provider, AiRequest request) async {
        cloudCalls += 1;
        throw const ServerFailure(
          'OpenAI API error 401: invalid_api_key',
        );
      },
      supportedProviders: () => const <String>['openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([providerName]) => 'OpenAI',
      automaticUseAllowed: (_) => true,
    );

    final service = DirectiveAwareInferenceService(
      loadSelectedModel: () async {
        selectedModelLoads += 1;
        return localModel;
      },
      loadRuntimeMode: () async => AiRuntimeMode.hybrid,
      runtimeProvider: localProvider,
      cloudRuntimeProvider: cloudProvider,
      sessionManager: RuntimeSessionManager(),
    );

    final chunks = await service
        .stream(
          const InferenceRequest(
            sessionId: 'cloud-only-no-local-fallback',
            prompt: 'hello',
            routeDirective: InferenceRouteDirective.cloudOnly,
            cloudProviderId: 'openAi',
            allowCloudProviderFailover: false,
          ),
        )
        .toList();

    expect(chunks, isNotEmpty);
    expect(chunks.last.isError, isTrue);
    expect(cloudCalls, 1);
    expect(localCalls, 0);
    expect(selectedModelLoads, 0);
  });
}

final class _CountingLocalRuntimeProvider extends LocalRuntimeProvider {
  _CountingLocalRuntimeProvider({required this.onStream});

  final void Function() onStream;

  @override
  bool supportsModel(AiModel model) => true;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    onStream();
    yield InferenceResponse.finalChunk(
      text: 'unexpected local response',
      tokensGenerated: 1,
      model: request.modelId ?? 'local',
    );
  }
}
