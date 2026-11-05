import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_provider_adapter.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_service_factory.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/nvidia_nim_large_models.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

void main() {
  for (final modelId in <String>[
    NvidiaNimLargeModels.kimiK26,
    NvidiaNimLargeModels.deepSeekV41Flash,
  ]) {
    test('$modelId uses NVIDIA Cloud with the pinned model, never Local',
        () async {
      final sl = GetIt.asNewInstance();
      final local = _CountingLocalRuntime();
      String? capturedProvider;
      String? capturedModel;
      sl.registerSingleton<LocalRuntimeProvider>(local);
      sl.registerSingleton<CloudRuntimeProvider>(
        CloudRuntimeProvider(
          sendQuery: (provider, request) async {
            capturedProvider = provider;
            capturedModel = request.modelId;
            return AiResponse(
              text: 'PROPOSAL: Synthetic success',
              model: request.modelId ?? '',
              tokensUsed: 6,
              timestamp: DateTime.now().millisecondsSinceEpoch,
            );
          },
          supportedProviders: () => const <String>['nvidiaNim'],
          isProviderAvailable: (provider) => provider == 'nvidiaNim',
          providerDisplayName: ([provider]) => provider ?? 'NVIDIA NIM',
          modelForProvider: (_) => modelId,
        ),
      );
      sl.registerSingleton<RuntimeSessionManager>(RuntimeSessionManager());

      final service = WorkshopInferenceServiceFactory.create(
        modelId: modelId,
        locator: sl,
      );
      final adapter = WorkshopInferenceProviderAdapter(
        inferenceService: service,
        modelId: modelId,
        role: AppAiRole.engineer,
      );
      await adapter.streamInference(
        request: const InferenceRequest(
          sessionId: 'workshop-large-nim',
          prompt: 'Return a synthetic proposal.',
          projectId: 'synthetic:project',
          taskId: 'synthetic:task',
        ),
        cancellationToken: CancellationToken(),
      ).drain<void>();

      expect(local.calls, 0);
      expect(capturedProvider, 'nvidiaNim');
      expect(capturedModel, modelId);
      await sl.reset();
    });
  }
}

final class _CountingLocalRuntime extends LocalRuntimeProvider {
  int calls = 0;
  @override
  bool supportsModel(AiModel model) => true;
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    calls++;
  }
}
