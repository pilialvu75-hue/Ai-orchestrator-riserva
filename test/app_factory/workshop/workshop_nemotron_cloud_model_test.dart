import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_storage.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_provider_adapter.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_service_factory.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

void main() {
  group('Nemotron Cloud Workshop model', () {
    test('is opt-in and can serve every Cantiere role', () {
      final model = WorkshopModelCatalogue.nvidiaNemotron3Ultra550b;

      expect(model.id, 'nvidia/nemotron-3-ultra-550b-a55b');
      expect(model.source, AiModelSource.cloud);
      expect(model.cloudProviderId, 'nvidiaNim');
      expect(model.optional, isTrue);
      expect(model.downloadUrl, isEmpty);

      for (final role in <AppAiRole>[
        AppAiRole.workshopOrchestrator,
        AppAiRole.architect,
        AppAiRole.engineer,
        AppAiRole.reviewer,
      ]) {
        expect(model.canServe(role), isTrue);
      }
    });

    test('does not require a local GGUF download', () async {
      final state = await const WorkshopModelStorage().inspect(
        WorkshopModelCatalogue.nvidiaNemotron3Ultra550b,
      );

      expect(state.isReady, isTrue);
      expect(state.needsDownload, isFalse);
      expect(state.path, isEmpty);
      expect(state.publicPath, isEmpty);
      expect(state.hasPersistentCopy, isFalse);
    });

    test('pins NVIDIA NIM and never enters the local runtime', () async {
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
              text: '{"status":"ok"}',
              model: request.modelId ?? 'unknown',
              tokensUsed: 8,
              timestamp: DateTime.now().millisecondsSinceEpoch,
            );
          },
          supportedProviders: () => const <String>['nvidiaNim'],
          isProviderAvailable: (provider) => provider == 'nvidiaNim',
          providerDisplayName: ([provider]) => provider ?? 'NVIDIA NIM',
          modelForProvider: (_) => 'nvidia/nemotron-3-ultra-550b-a55b',
        ),
      );
      sl.registerSingleton<RuntimeSessionManager>(RuntimeSessionManager());

      final model = WorkshopModelCatalogue.nvidiaNemotron3Ultra550b;
      final service = WorkshopInferenceServiceFactory.create(
        modelId: model.id,
        locator: sl,
      );
      final adapter = WorkshopInferenceProviderAdapter(
        inferenceService: service,
        modelId: model.id,
        role: AppAiRole.engineer,
      );

      await adapter
          .streamInference(
            request: const InferenceRequest(
              sessionId: 'workshop-nemotron-cloud',
              prompt: 'Return a valid Workshop JSON proposal.',
              projectId: 'project:test',
              taskId: 'task:test',
            ),
            cancellationToken: CancellationToken(),
          )
          .drain<void>();

      expect(local.calls, 0);
      expect(capturedProvider, 'nvidiaNim');
      expect(capturedModel, 'nvidia/nemotron-3-ultra-550b-a55b');

      await sl.reset();
    });
  });
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
    calls += 1;
  }
}
