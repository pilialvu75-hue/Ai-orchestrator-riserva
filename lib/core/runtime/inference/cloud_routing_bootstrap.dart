import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/core/config/ai/assistant_system_prompt_service.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_natural_memory_consent_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_relational_memory_consent_service.dart';
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
import 'package:ai_orchestrator/core/runtime/inference/assistant_resident_local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_assistant_runtime_bundle.dart';
import 'package:ai_orchestrator/core/runtime/inference/directive_aware_inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/tools/search/assistant_public_web_link.dart';
import 'package:ai_orchestrator/core/tools/search/duckduckgo_lite_provider.dart';
import 'package:ai_orchestrator/core/tools/search/duckduckgo_provider.dart';
import 'package:ai_orchestrator/core/tools/search/expiring_search_cache.dart';
import 'package:ai_orchestrator/core/tools/search/fallback_search_provider.dart';
import 'package:ai_orchestrator/core/tools/web_search_tool.dart';
import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/presentation/services/hybrid_cloud_chat_consent_gateway.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/repositories/ai_repository.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_image_vision_service.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_local_image_vision_service.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_video_storyboard_service.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_file_context_service.dart';
import 'package:ai_orchestrator/features/document_intelligence/data/services/local_document_index_service.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
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
  /// The explicit opt-in is an integration/QA gate, not an implicit upgrade
  /// of every existing Cloud account. The release bootstrap calls this with
  /// the default (false), preserving the original Cloud Chat transport until
  /// verified account setup and on-device acceptance are completed.
  static Future<void> configure(
    GetIt sl, {
    bool enableConsentGatedAssistantCloud = false,
    AssistantPublicWebReader? publicWebReader,
  }) async {
    await _unregisterIfPresent<HybridCloudAssistantRuntimeBundle>(sl);
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
    final durableMemoryCaptureService =
        sl<AssistantDurableMemoryCaptureService>();
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
    final residentAssistantRuntime = AssistantResidentLocalRuntimeProvider(delegate: sl<LocalRuntimeProvider>());
    final assistantLocalRuntimeProvider =
        AssistantWebContinuationLocalRuntimeProvider(
      delegate: residentAssistantRuntime,
    );
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      // Start the measured GPU model while the UI opens, without a synthetic
      // answer. A request arriving during preparation awaits the same future.
      unawaited(() async {
        try {
          if (await sl<AiRuntimeSettingsService>().loadRuntimeMode() != AiRuntimeMode.local) return;
          final selected = await sl<LocalAiRepository>().getSelectedModel();
          final model = selected.fold((_) => null, (model) => model);
          if (model != null) await residentAssistantRuntime.prepareSelectedModel(model);
        } catch (_) {
          // Optional preparation never blocks app startup or ordinary routing.
        }
      }());
    }

    sl.registerLazySingleton<CloudBackgroundExecutionJournal>(
      () => CloudBackgroundExecutionJournal(
        preferences: sl<SharedPreferences>(),
      ),
    );

    // This bundle is bound to the ACTUAL Chat review gateway and to the
    // existing OS-protected local identity. It is opt-in until tested on a
    // physical device and ordinary Cloud credentials can be migrated safely.
    // It NEVER replaces the global CloudRuntimeProvider used by Workshop.
    final assistantConsentBundle = enableConsentGatedAssistantCloud
        ? HybridCloudAssistantRuntimeBundle.create(
            credentials: CloudCredentialStore.instance,
            protectedStorage: FlutterSecureCloudConsentStorage(),
            client: sl<http.Client>(),
            supportedProviders: () => sl<AiRepository>().supportedProviders,
            isProviderAvailable: (provider) =>
                sl<AiRepository>().isProviderAvailable(provider),
            providerDisplayName: ([provider]) =>
                sl<AiRepository>().providerDisplayName(provider),
            chatReview: (chatSessionId, review, isRequestActive) =>
                HybridCloudChatConsentGateway.instance.ask(
              chatSessionId: chatSessionId,
              review: review,
              isRequestActive: isRequestActive,
            ),
          )
        : null;
    // Expose the exact same protected consent manager/identity to Settings.
    // Never register this bundle in normal builds: Settings stays inactive.
    if (assistantConsentBundle != null) {
      sl.registerSingleton<HybridCloudAssistantRuntimeBundle>(
        assistantConsentBundle,
      );
    }

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
        // Preserve ordinary CLOUD providers (NVIDIA, Mistral, custom, etc.)
        // while routing HYBRID through the exact approved OpenAI/Gemini gate.
        cloudRuntimeProvider: sl<CloudRuntimeProvider>(),
        hybridConsentCloudRuntimeProvider: assistantConsentBundle?.provider,
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
        publicWebReader: publicWebReader,
        intentAnalyzer: sl<IntentAnalyzer>(),
        executor: sl<ExecutionEngine>(),
        inferenceService: sl<InferenceService>(),
        plannerService: sl<PlannerService>(),
        webSearchTool: assistantWebSearchTool,
        runtimeSettingsService: sl<AiRuntimeSettingsService>(),
        cloudRuntimeProvider: assistantConsentBundle?.provider ?? sl<CloudRuntimeProvider>(),
        // Memory is resolved AFTER Hannibal chooses localOnly, never as part
        // of an HYBRID shared prompt that might be forwarded to Cloud.
        hybridLocalMemoryPromptEnricher: ({
          required String baseSystemPrompt,
          required String sessionId,
          required String userPrompt,
        }) => durableMemoryContextService.augmentSystemPrompt(
          baseSystemPrompt: baseSystemPrompt,
          sessionId: sessionId,
          userPrompt: userPrompt,
        ),
      ),
    );

    sl.registerLazySingleton<ChatRepository>(
      () => PromptResolvingChatRepository(
        systemPromptService: assistantSystemPromptService,
        durableMemoryContextService: durableMemoryContextService,
        runtimeMode: () => sl<AiRuntimeSettingsService>().runtimeMode,
        durableMemoryCaptureService: durableMemoryCaptureService,
        naturalMemoryConsentService: sl<AssistantNaturalMemoryConsentService>(),
        relationalMemoryConsentService: sl<AssistantRelationalMemoryConsentService>(),
        delegate: CloudWebEnrichingChatRepository(
          // This decorator is only active in explicit CLOUD. Its existing
          // Web enrichment remains available; HYBRID Web is handled by the
          // consent-aware AssistantWebAwareOrchestrator instead.
          consentGatedAssistantCloud: false,
          runtimeMode: () => sl<AiRuntimeSettingsService>().runtimeMode,
          webSearchTool: assistantWebSearchTool,
          delegate: ChatRepositoryImpl(
            localDataSource: sl<ChatLocalDataSource>(),
            conversationMemoryService: sl<ConversationMemoryService>(),
            inferenceService: sl<InferenceService>(),
            runtimeSettingsService: sl<AiRuntimeSettingsService>(),
            imageVisionService: CloudChatImageVisionService(),
            localImageVisionService: AndroidChatLocalImageVisionService(),
            videoStoryboardService: AndroidChatVideoStoryboardService(),
            // Ordinary CLOUD preserves its visual and document behavior.
            // HYBRID still validates trusted Chat provenance at the
            // protected runtime boundary and never auto-shares attachments.
            consentGatedAssistantCloud: false,
            fileContextService: ChatFileContextService(
              indexService: sl<LocalDocumentIndexService>(),
              databaseHelper: sl<DatabaseHelper>(),
            ),
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
