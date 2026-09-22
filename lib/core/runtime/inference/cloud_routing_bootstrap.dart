import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/core/config/ai/assistant_system_prompt_service.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/orchestrator/assistant_web_aware_orchestrator.dart';
import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';
import 'package:ai_orchestrator/core/orchestrator/intent_analyzer.dart';
import 'package:ai_orchestrator/core/orchestrator/orchestrator.dart';
import 'package:ai_orchestrator/core/planner/planner_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/background/cloud_background_execution_journal.dart';
import 'package:ai_orchestrator/core/runtime/background/cloud_background_execution_lease.dart';
import 'package:ai_orchestrator/core/runtime/inference/assistant_web_continuation_local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/directive_aware_inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/tools/search/duckduckgo_lite_provider.dart';
import 'package:ai_orchestrator/core/tools/search/duckduckgo_provider.dart';
import 'package:ai_orchestrator/core/tools/search/expiring_search_cache.dart';
import 'package:ai_orchestrator/core/tools/search/fallback_search_provider.dart';
import 'package:ai_orchestrator/core/tools/web_search_tool.dart';
import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/cloud_web_enriching_chat_repository.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/prompt_resolving_chat_repository.dart';
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
    await _unregisterIfPresent<CloudBackgroundExecutionJournal>(sl);

    final assistantSystemPromptService = AssistantSystemPromptService(
      configRepository: sl<ConfigRepository>(),
    );
    final durableMemoryContextService = AssistantDurableMemoryContextService(
      memoryService: sl<AssistantDurableMemoryService>(),
    );
    final migratedLegacyPrompt =
        await assistantSystemPromptService.migrateLegacyDefaultIfNeeded();
    if (migratedLegacyPrompt) {
      debugPrint(
        '[ASSISTANT_PROMPT] migrated legacy bundled prompt to conversational core',
      );
    }

    // Assistant-only search stack. General ranked Web results come from
    // DuckDuckGo Lite; the existing Instant Answer provider remains a fallback.
    // The cache is intentionally short-lived so time-sensitive facts cannot
    // remain stale for the lifetime of the app process. Detailed exception text
    // is suppressed end-to-end because HTTP exceptions can contain the user's
    // query-bearing URI. The global WebSearchTool registration is untouched,
    // keeping Workshop/Cantiere behavior unchanged.
    final assistantWebSearchTool = WebSearchTool(
      searchProvider: FallbackSearchProvider(
        primary: DuckDuckGoLiteProvider(
          client: sl<http.Client>(),
          includeErrorDetailsInDiagnostics: false,
        ),
        fallback: DuckDuckGoProvider(
          client: sl<http.Client>(),
          timeout: const Duration(seconds: 4),
          enableDetailedDebugLogging: false,
          includeErrorDetailsInDiagnostics: false,
        ),
        includeErrorDetailsInDiagnostics: false,
      ),
      searchCache: ExpiringSearchCache(),
      includeErrorDetailsInDiagnostics: false,
    );

    // Assistant-only runtime decorator. The globally registered Local runtime
    // remains the canonical FFI/desktop provider used by diagnostics, Workshop
    // and the rest of the application.
    final assistantLocalRuntimeProvider =
        AssistantWebContinuationLocalRuntimeProvider(
      delegate: sl<LocalRuntimeProvider>(),
    );

    sl.registerLazySingleton<CloudBackgroundExecutionJournal>(
      () => CloudBackgroundExecutionJournal(
        preferences: sl<SharedPreferences>(),
      ),
    );

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
        runtimeProvider: assistantLocalRuntimeProvider,
        cloudRuntimeProvider: sl<CloudRuntimeProvider>(),
        sessionManager: sl<RuntimeSessionManager>(),
        webSearchTool: assistantWebSearchTool,
        backgroundExecutionLeaseService:
            CloudBackgroundExecutionLeaseService(),
        backgroundExecutionJournal: sl<CloudBackgroundExecutionJournal>(),
      ),
    );

    sl.registerLazySingleton<PlannerService>(
      () => PlannerService(
        inferenceService: sl<InferenceService>(),
      ),
    );

    sl.registerLazySingleton<Orchestrator>(
      () => AssistantWebAwareOrchestrator(
        intentAnalyzer: sl<IntentAnalyzer>(),
        executor: sl<ExecutionEngine>(),
        inferenceService: sl<InferenceService>(),
        plannerService: sl<PlannerService>(),
        webSearchTool: assistantWebSearchTool,
        runtimeSettingsService: sl<AiRuntimeSettingsService>(),
        cloudRuntimeProvider: sl<CloudRuntimeProvider>(),
      ),
    );

    sl.registerLazySingleton<ChatRepository>(
      () => PromptResolvingChatRepository(
        systemPromptService: assistantSystemPromptService,
        durableMemoryContextService: durableMemoryContextService,
        delegate: CloudWebEnrichingChatRepository(
          runtimeMode: () => sl<AiRuntimeSettingsService>().runtimeMode,
          webSearchTool: assistantWebSearchTool,
          delegate: ChatRepositoryImpl(
            localDataSource: sl<ChatLocalDataSource>(),
            conversationMemoryService: sl<ConversationMemoryService>(),
            inferenceService: sl<InferenceService>(),
            runtimeSettingsService: sl<AiRuntimeSettingsService>(),
            // Important: do not resolve Orchestrator here. Explicit Cloud chat
            // must remain constructible and usable even if Hannibal is unavailable.
            orchestratorProvider: () => sl<Orchestrator>(),
          ),
        ),
      ),
    );

    debugPrint(
      '[CLOUD_ROUTING] direct Cloud safety path, Assistant general web search, '
      'privacy-safe diagnostics, Hybrid web-aware Hannibal routing, '
      'Local web continuation guard, Cloud background execution lease, '
      'and recovery journal wired',
    );
  }

  static Future<void> _unregisterIfPresent<T extends Object>(GetIt sl) async {
    if (sl.isRegistered<T>()) {
      await sl.unregister<T>();
    }
  }
}
