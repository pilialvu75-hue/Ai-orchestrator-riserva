import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';
import 'package:ai_orchestrator/core/orchestrator/intent_analyzer.dart';
import 'package:ai_orchestrator/core/orchestrator/orchestrator.dart';
import 'package:ai_orchestrator/core/planner/planner_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/directive_aware_inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/tools/web_search_tool.dart';
import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/chat_memory/conversation_memory_service.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';

/// Rebinds only the routing-sensitive services after the standard dependency
/// graph has been registered.
///
/// Keeping this separate from the main container minimizes regression risk for
/// the large Local/voice/build dependency graph.
abstract final class CloudRoutingBootstrap {
  static Future<void> configure(GetIt sl) async {
    await _unregisterIfPresent<ChatRepository>(sl);
    await _unregisterIfPresent<Orchestrator>(sl);
    await _unregisterIfPresent<PlannerService>(sl);
    await _unregisterIfPresent<InferenceService>(sl);

    sl.registerLazySingleton<InferenceService>(
      () => DirectiveAwareInferenceService(
        loadSelectedModel: () async {
          final result = await sl<LocalAiRepository>().getSelectedModel();
          return result.fold(
            (failure) {
              debugPrint(
                '[RUNTIME] model selection failed: ${failure.message}',
              );
              return null;
            },
            (model) => model,
          );
        },
        loadRuntimeMode: () =>
            sl<AiRuntimeSettingsService>().loadRuntimeMode(),
        runtimeProvider: sl<LocalRuntimeProvider>(),
        cloudRuntimeProvider: sl<CloudRuntimeProvider>(),
        sessionManager: sl<RuntimeSessionManager>(),
      ),
    );

    sl.registerLazySingleton<PlannerService>(
      () => PlannerService(
        inferenceService: sl<InferenceService>(),
      ),
    );

    sl.registerLazySingleton<Orchestrator>(
      () => Orchestrator(
        intentAnalyzer: sl<IntentAnalyzer>(),
        executor: sl<ExecutionEngine>(),
        inferenceService: sl<InferenceService>(),
        plannerService: sl<PlannerService>(),
        webSearchTool: sl<WebSearchTool>(),
        runtimeSettingsService: sl<AiRuntimeSettingsService>(),
        cloudRuntimeProvider: sl<CloudRuntimeProvider>(),
      ),
    );

    sl.registerLazySingleton<ChatRepository>(
      () => ChatRepositoryImpl(
        localDataSource: sl<ChatLocalDataSource>(),
        conversationMemoryService: sl<ConversationMemoryService>(),
        inferenceService: sl<InferenceService>(),
        runtimeSettingsService: sl<AiRuntimeSettingsService>(),
        // Important: do not resolve Orchestrator here. Explicit Cloud chat must
        // remain constructible and usable even if Hannibal is unavailable.
        orchestratorProvider: () => sl<Orchestrator>(),
      ),
    );

    debugPrint(
      '[CLOUD_ROUTING] direct Cloud safety path and Hybrid Hannibal routing wired',
    );
  }

  static Future<void> _unregisterIfPresent<T extends Object>(GetIt sl) async {
    if (sl.isRegistered<T>()) {
      await sl.unregister<T>();
    }
  }
}
