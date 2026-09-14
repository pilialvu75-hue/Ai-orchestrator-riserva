import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/background/cloud_background_execution_lease.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/directive_aware_inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('cloudOnly holds one Android background lease until stream completion',
      () async {
    const channel = MethodChannel('test/cloud_background_execution');
    final methodCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methodCalls.add(call);
      return <String, Object>{'ok': true};
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final localProvider = _CountingLocalRuntimeProvider(onStream: () {});
    final cloudProvider = CloudRuntimeProvider(
      sendQuery: (String provider, AiRequest request) async => AiResponse(
        text: 'cloud answer',
        model: 'test-cloud-model',
        tokensUsed: 4,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
      supportedProviders: () => const <String>['gemini'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([providerName]) => 'Gemini',
      automaticUseAllowed: (_) => true,
    );

    final service = DirectiveAwareInferenceService(
      loadSelectedModel: () async => null,
      loadRuntimeMode: () async => AiRuntimeMode.cloud,
      runtimeProvider: localProvider,
      cloudRuntimeProvider: cloudProvider,
      sessionManager: RuntimeSessionManager(),
      backgroundExecutionLeaseService: CloudBackgroundExecutionLeaseService(
        channel: channel,
        platformOverride: TargetPlatform.android,
      ),
    );

    final chunks = await service
        .stream(
          const InferenceRequest(
            sessionId: 'background-cloud',
            prompt: 'hello',
            routeDirective: InferenceRouteDirective.cloudOnly,
            cloudProviderId: 'gemini',
            allowCloudProviderFailover: false,
          ),
        )
        .toList();

    expect(chunks.last.text, 'cloud answer');
    expect(methodCalls.map((call) => call.method).toList(), <String>[
      'acquire',
      'release',
    ]);
    expect(
      (methodCalls.first.arguments as Map<Object?, Object?>)['sessionId'],
      'background-cloud',
    );
    expect(
      (methodCalls.first.arguments as Map<Object?, Object?>)['provider'],
      'gemini',
    );
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
