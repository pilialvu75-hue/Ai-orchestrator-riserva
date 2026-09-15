import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

/// Regression matrix for the runtime/connectivity contract.
///
/// "Offline" here is the authoritative per-request `isOffline` signal. Web
/// enrichment has its own focused tests; this matrix protects the lower routing
/// invariant that no Cloud provider may be invoked for an explicitly offline
/// request and that Cloud/Hybrid can fall back to an available Local runtime.
void main() {
  const model = AiModel(
    id: 'gemma_2b',
    displayName: 'Gemma 2B',
    fileName: 'gemma.gguf',
    downloadUrl: 'https://example.invalid/gemma.gguf',
    version: '1.0.0',
    sizeBytes: 1024,
    description: 'Connectivity matrix model',
    isDownloaded: true,
    localPath: '/tmp/gemma.gguf',
    validationStatus: ModelValidationStatus.validatedOk,
  );

  group('Local / Hybrid / Cloud connectivity matrix', () {
    test('Local + online stays Local', () async {
      final harness = _Harness(mode: AiRuntimeMode.local, model: model);

      final response = await harness.service.infer(
        const InferenceRequest(
          sessionId: 'matrix-local-online',
          prompt: 'stable question',
        ),
      );

      expect(response.text, 'local');
      expect(response.isError, isFalse);
      expect(harness.local.calls, 1);
      expect(harness.cloudCalls, 0);
      expect(harness.local.lastRequest?.isOffline, isFalse);
    });

    test('Local + offline stays Local and preserves offline authority', () async {
      final harness = _Harness(mode: AiRuntimeMode.local, model: model);

      final response = await harness.service.infer(
        const InferenceRequest(
          sessionId: 'matrix-local-offline',
          prompt: 'offline question',
          isOffline: true,
        ),
      );

      expect(response.text, 'local');
      expect(response.isError, isFalse);
      expect(harness.local.calls, 1);
      expect(harness.cloudCalls, 0);
      expect(harness.local.lastRequest?.isOffline, isTrue);
    });

    test('Hybrid + online can remain Local-first', () async {
      final harness = _Harness(mode: AiRuntimeMode.hybrid, model: model);

      final response = await harness.service.infer(
        const InferenceRequest(
          sessionId: 'matrix-hybrid-online',
          prompt: 'simple local task',
        ),
      );

      expect(response.text, 'local');
      expect(response.isError, isFalse);
      expect(harness.local.calls, 1);
      expect(harness.cloudCalls, 0);
    });

    test('Hybrid + offline is forced Local and never invokes Cloud', () async {
      final harness = _Harness(mode: AiRuntimeMode.hybrid, model: model);

      final response = await harness.service.infer(
        const InferenceRequest(
          sessionId: 'matrix-hybrid-offline',
          prompt: 'current fact while offline',
          isOffline: true,
        ),
      );

      expect(response.text, 'local');
      expect(response.isError, isFalse);
      expect(harness.local.calls, 1);
      expect(harness.cloudCalls, 0);
      expect(harness.local.lastRequest?.isOffline, isTrue);
    });

    test('Cloud + online uses Cloud as the primary runtime', () async {
      final harness = _Harness(mode: AiRuntimeMode.cloud, model: model);

      final response = await harness.service.infer(
        const InferenceRequest(
          sessionId: 'matrix-cloud-online',
          prompt: 'remote task',
        ),
      );

      expect(response.text, 'cloud');
      expect(response.isError, isFalse);
      expect(harness.cloudCalls, 1);
      expect(harness.local.calls, 0);
    });

    test('Cloud + offline falls back Local and never invokes Cloud', () async {
      final harness = _Harness(mode: AiRuntimeMode.cloud, model: model);

      final response = await harness.service.infer(
        const InferenceRequest(
          sessionId: 'matrix-cloud-offline',
          prompt: 'remote mode but no network allowed',
          isOffline: true,
        ),
      );

      expect(response.text, 'local');
      expect(response.isError, isFalse);
      expect(harness.cloudCalls, 0);
      expect(harness.local.calls, 1);
      expect(harness.local.lastRequest?.isOffline, isTrue);
    });

    test('Cloud + offline fails explicitly when no Local runtime is ready',
        () async {
      final harness = _Harness(mode: AiRuntimeMode.cloud, model: null);

      final response = await harness.service.infer(
        const InferenceRequest(
          sessionId: 'matrix-cloud-offline-no-local',
          prompt: 'offline with no local model',
          isOffline: true,
        ),
      );

      expect(response.isError, isTrue);
      expect(
        response.errorMessage,
        contains('no local model is ready'),
      );
      expect(harness.cloudCalls, 0);
      expect(harness.local.calls, 0);
    });
  });
}

final class _Harness {
  _Harness({
    required AiRuntimeMode mode,
    required AiModel? model,
  }) {
    local = _CountingLocalRuntime();
    cloud = CloudRuntimeProvider(
      sendQuery: (_, __) async {
        cloudCalls += 1;
        return AiResponse(
          text: 'cloud',
          model: 'cloud-test',
          tokensUsed: 1,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
      },
      supportedProviders: () => const <String>['openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([providerName]) => 'OpenAI',
      automaticUseAllowed: (_) => true,
    );
    service = InferenceService(
      loadSelectedModel: () async => model,
      loadRuntimeMode: () async => mode,
      runtimeProvider: local,
      cloudRuntimeProvider: cloud,
      sessionManager: RuntimeSessionManager(),
    );
  }

  late final _CountingLocalRuntime local;
  late final CloudRuntimeProvider cloud;
  late final InferenceService service;
  int cloudCalls = 0;
}

final class _CountingLocalRuntime extends LocalRuntimeProvider {
  int calls = 0;
  InferenceRequest? lastRequest;

  @override
  bool supportsModel(AiModel model) => true;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    calls += 1;
    lastRequest = request;
    yield InferenceResponse.finalChunk(
      text: 'local',
      tokensGenerated: 1,
      model: request.modelId ?? 'local-test',
    );
  }
}
