import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/tools/web_search_tool.dart';

/// Builds the lightweight inference service used by one Workshop role/model.
///
/// The Workshop keeps its own logical model selection while sharing the
/// application-level runtime providers and session manager. This prevents an
/// explicit Workshop model from silently falling back to the Assistant model.
abstract final class WorkshopInferenceServiceFactory {
  static InferenceService create({
    required String modelId,
    GetIt? locator,
  }) {
    final normalizedModelId = modelId.trim();
    if (normalizedModelId.isEmpty) {
      throw ArgumentError.value(
        modelId,
        'modelId',
        'Workshop model id cannot be empty.',
      );
    }

    final sl = locator ?? GetIt.instance;

    return InferenceService(
      loadSelectedModel: () => resolveInstalledModel(
        modelId: normalizedModelId,
        repository: sl<LocalAiRepository>(),
      ),
      // Cantiere owns its runtime decision. The Assistant's persisted
      // Local/Cloud/Hybrid preference must never leak into Workshop inference.
      // Current Workshop model assignments are local GGUF models, so this
      // boundary remains local-only until a Cantiere-owned route explicitly
      // selects remote/cloud inference.
      loadRuntimeMode: () async => AiRuntimeMode.local,
      runtimeProvider: sl<LocalRuntimeProvider>(),
      cloudRuntimeProvider: sl<CloudRuntimeProvider>(),
      sessionManager: sl<RuntimeSessionManager>(),
      webSearchTool:
          sl.isRegistered<WebSearchTool>() ? sl<WebSearchTool>() : null,
    );
  }

  /// Resolves the exact Workshop model from the shared installed-model store.
  ///
  /// Matching by both catalogue id and effective runtime id keeps imported or
  /// aliased models compatible without consulting the Assistant selection.
  static Future<AiModel?> resolveInstalledModel({
    required String modelId,
    required LocalAiRepository repository,
  }) async {
    final normalizedModelId = modelId.trim();
    if (normalizedModelId.isEmpty) {
      return null;
    }

    final result = await repository.getAvailableModels();

    return result.fold(
      (failure) {
        debugPrint(
          '[WORKSHOP_MODEL_RESOLVE] model=$normalizedModelId '
          'status=repository_error error=${failure.message}',
        );
        return null;
      },
      (models) {
        for (final model in models) {
          if (model.id == normalizedModelId ||
              model.effectiveRuntimeModelId == normalizedModelId) {
            debugPrint(
              '[WORKSHOP_MODEL_RESOLVE] model=$normalizedModelId '
              'status=found downloaded=${model.isDownloaded} '
              "path=${model.localPath ?? 'none'}",
            );
            return model;
          }
        }

        debugPrint(
          '[WORKSHOP_MODEL_RESOLVE] model=$normalizedModelId status=not_found',
        );
        return null;
      },
    );
  }
}
