import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/ai/model_manager.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/memory/context_window_manager.dart';
import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';
import 'package:ai_orchestrator/core/orchestrator/intent_analyzer.dart';
import 'package:ai_orchestrator/core/orchestrator/orchestrator.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/orchestrator_state_engine.dart';
import 'package:ai_orchestrator/core/planner/planner_service.dart';
import 'package:ai_orchestrator/core/plugins/plugin_registry.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/language_service.dart';
import 'package:ai_orchestrator/core/services/cache_manager.dart';
import 'package:ai_orchestrator/core/system/update/update_checker.dart';
import 'package:ai_orchestrator/core/system/update/update_manager.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/copilot_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/claude_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/gemini_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/grok_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/openai_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/repositories/ai_repository_impl.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/repositories/ai_repository.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/usecases/send_ai_query.dart';
import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/load_chat_messages.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/prune_chat_history.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/send_chat_message.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:ai_orchestrator/features/coding_assistant/coding_assistant_agent_impl.dart';
import 'package:ai_orchestrator/features/coding_assistant/sequential_planning_strategy.dart';
import 'package:ai_orchestrator/features/document_intelligence/data/services/local_document_index_service.dart';
import 'package:ai_orchestrator/features/document_intelligence/offline_document_intelligence_plugin.dart';
import 'package:ai_orchestrator/features/local_ai/data/repositories/local_ai_repository_impl.dart';
import 'package:ai_orchestrator/features/local_ai/data/services/model_download_service.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';
import 'package:ai_orchestrator/features/local_ai/domain/usecases/local_ai_usecases.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/multimodal/data/services/image_service.dart';
import 'package:ai_orchestrator/features/multimodal/data/services/file_attachment_service.dart';
import 'package:ai_orchestrator/features/onboarding/data/datasources/model_registry_datasource.dart';
import 'package:ai_orchestrator/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:ai_orchestrator/features/projects/data/datasources/project_memory_local_datasource.dart';
import 'package:ai_orchestrator/features/projects/data/repositories/project_memory_repository_impl.dart';
import 'package:ai_orchestrator/features/projects/domain/repositories/project_memory_repository.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/delete_all_project_memories.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/delete_project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/get_latest_project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/get_project_memories.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/save_project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/update_project_memory.dart';
import 'package:ai_orchestrator/features/projects/presentation/bloc/project_memory_bloc.dart';
import 'package:ai_orchestrator/features/voice/data/services/speech_service.dart';
import 'package:ai_orchestrator/features/voice/data/adapters/device_voice_adapters.dart';
import 'package:ai_orchestrator/features/voice/data/adapters/sherpa_onnx_voice_adapter.dart';
import 'package:ai_orchestrator/features/voice/data/normalization/voice_text_normalizer.dart';
import 'package:ai_orchestrator/native/platform/android_intent_handler.dart';
import 'package:ai_orchestrator/native/platform/bixby_handler.dart';
import 'package:ai_orchestrator/native/runtime/execution_engine_factory.dart';
import 'package:ai_orchestrator/native/runtime/local_runtime_provider_factory.dart';

final sl = GetIt.instance;

Future<void> initDependencies({
  String openAiApiKey = '',
  String geminiApiKey = '',
  String claudeApiKey = '',
  String grokApiKey = '',
  String copilotApiKey = '',
  String appVersion = '1.0.0',
}) async {
  // ── External ──────────────────────────────────────────────────────────────
  sl.registerLazySingleton<http.Client>(() => http.Client());
  final sharedPreferences = await SharedPreferences.getInstance();
  sl.registerSingleton<SharedPreferences>(sharedPreferences);
  sl.registerLazySingleton<PreferencesService>(
    () => PreferencesService(sl<SharedPreferences>()),
  );
  sl.registerLazySingleton<ConfigRepository>(
    () => ConfigRepository(sl<PreferencesService>()),
  );
  sl.registerLazySingleton<AiRuntimeSettingsService>(
    () => AiRuntimeSettingsService(configRepository: sl<ConfigRepository>()),
  );
  final languageService =
      LanguageService(configRepository: sl<ConfigRepository>());
  await languageService.loadSavedLanguage();
  sl.registerSingleton<LanguageService>(languageService);

  // ── Core ──────────────────────────────────────────────────────────────────
  sl.registerSingleton<DatabaseHelper>(DatabaseHelper.instance);
  sl.registerLazySingleton<LocalDocumentIndexService>(
    () => LocalDocumentIndexService(databaseHelper: sl<DatabaseHelper>()),
  );
  sl.registerLazySingleton<AndroidIntentHandler>(() => AndroidIntentHandler());
  sl.registerLazySingleton<BixbyHandler>(() => const BixbyHandler());
  sl.registerLazySingleton<CacheManager>(() => const CacheManager());
  sl.registerLazySingleton<OfflineDocumentIntelligencePlugin>(
    () => OfflineDocumentIntelligencePlugin(
      indexService: sl<LocalDocumentIndexService>(),
    ),
  );

  if (PluginRegistry.instance.get(OfflineDocumentIntelligencePlugin.pluginId) ==
      null) {
    await PluginRegistry.instance.register(
      sl<OfflineDocumentIntelligencePlugin>(),
    );
  }
  sl.registerLazySingleton<VersionComparator>(() => const VersionComparator());
  sl.registerLazySingleton<UpdateChecker>(
    () => UpdateChecker(
      httpClient: sl<http.Client>(),
      preferences: sl<SharedPreferences>(),
      comparator: sl<VersionComparator>(),
      manifestUrl: AppConstants.updateManifestUrl,
      githubOwner: AppConstants.updateGitHubOwner,
      githubRepo: AppConstants.updateGitHubRepo,
    ),
  );
  sl.registerLazySingleton<UpdateManager>(
    () => UpdateManager(
      updateChecker: sl<UpdateChecker>(),
      comparator: sl<VersionComparator>(),
      preferences: sl<SharedPreferences>(),
      intentHandler: sl<AndroidIntentHandler>(),
      currentVersion: appVersion,
    ),
  );
  sl.registerLazySingleton<ContextWindowManager>(
    () => ContextWindowManager(databaseHelper: sl<DatabaseHelper>()),
  );

  // ── Core AI ────────────────────────────────────────────────────────────────
  sl.registerLazySingleton<ModelManager>(() => const ModelManager());
  sl.registerLazySingleton<LocalRuntimeProvider>(() => createLocalRuntimeProvider());

  // ── AI data sources ────────────────────────────────────────────────────────
  sl.registerLazySingleton<OpenAiDataSource>(
    () => OpenAiDataSource(
        apiKey: openAiApiKey, httpClient: sl<http.Client>()),
  );
  sl.registerLazySingleton<GeminiDataSource>(
    () => GeminiDataSource(
        apiKey: geminiApiKey, httpClient: sl<http.Client>()),
  );
  sl.registerLazySingleton<ClaudeDataSource>(
    () => ClaudeDataSource(
      apiKey: claudeApiKey,
      httpClient: sl<http.Client>(),
    ),
  );
  sl.registerLazySingleton<GrokDataSource>(
    () => GrokDataSource(
        apiKey: grokApiKey, httpClient: sl<http.Client>()),
  );
  sl.registerLazySingleton<CopilotDataSource>(
    () => CopilotDataSource(
        apiKey: copilotApiKey, httpClient: sl<http.Client>()),
  );

  // ── Project memory ─────────────────────────────────────────────────────────
  sl.registerLazySingleton<ProjectMemoryLocalDataSource>(
    () => ProjectMemoryLocalDataSourceImpl(
        databaseHelper: sl<DatabaseHelper>()),
  );
  sl.registerLazySingleton<ProjectMemoryRepository>(
    () => ProjectMemoryRepositoryImpl(
        localDataSource: sl<ProjectMemoryLocalDataSource>()),
  );

  // ── Chat ───────────────────────────────────────────────────────────────────
  sl.registerLazySingleton<ChatLocalDataSource>(
    () => ChatLocalDataSourceImpl(databaseHelper: sl<DatabaseHelper>()),
  );

  // ── Onboarding ─────────────────────────────────────────────────────────────
  sl.registerLazySingleton<ModelRegistryDataSource>(
    () => const ModelRegistryDataSource(),
  );

  // ── Local AI (offline model download / selection) ──────────────────────────
  sl.registerLazySingleton<ModelDownloadService>(() => ModelDownloadService());
  sl.registerLazySingleton<LocalAiRepository>(
    () => LocalAiRepositoryImpl(downloadService: sl<ModelDownloadService>()),
  );
  sl.registerLazySingleton<LocalRuntimeDiagnosticsService>(
    () => LocalRuntimeDiagnosticsService(
      runtimeProvider: sl<LocalRuntimeProvider>(),
      localAiRepository: sl<LocalAiRepository>(),
    ),
  );
  sl.registerLazySingleton(() => GetAvailableModels(sl<LocalAiRepository>()));
  sl.registerLazySingleton(() => DownloadModel(sl<LocalAiRepository>()));
  sl.registerLazySingleton(() => ImportLocalModel(sl<LocalAiRepository>()));
  sl.registerLazySingleton(
      () => DownloadModelFromUrl(sl<LocalAiRepository>()));
  sl.registerLazySingleton(() => CheckForUpdates(sl<LocalAiRepository>()));
  sl.registerLazySingleton(() => SelectModel(sl<LocalAiRepository>()));
  sl.registerLazySingleton(() => GetSelectedModel(sl<LocalAiRepository>()));

  // ── Voice ─────────────────────────────────────────────────────────────────
  sl.registerLazySingleton<VoiceTextNormalizer>(
    () => const VoiceTextNormalizer(),
  );
  sl.registerLazySingleton<SherpaOnnxVoiceAdapter>(
    () => SherpaOnnxVoiceAdapter(),
  );
  sl.registerLazySingleton<DeviceSpeechToTextAdapter>(
    () => DeviceSpeechToTextAdapter(),
  );
  sl.registerLazySingleton<DeviceFlutterTtsAdapter>(
    () => DeviceFlutterTtsAdapter(),
  );
  sl.registerLazySingleton<SpeechService>(
    () => SpeechService(
      primaryAsr: sl<SherpaOnnxVoiceAdapter>(),
      fallbackAsr: sl<DeviceSpeechToTextAdapter>(),
      primaryTts: sl<SherpaOnnxVoiceAdapter>(),
      fallbackTts: sl<DeviceFlutterTtsAdapter>(),
      sharedAsrAdapter: false,
      sharedTtsAdapter: false,
      normalizer: sl<VoiceTextNormalizer>(),
    ),
  );

  // ── Multimodal ────────────────────────────────────────────────────────────
  sl.registerLazySingleton<ImageService>(() => ImageService());
  sl.registerLazySingleton<FileAttachmentService>(() => FileAttachmentService());

  // ── Orchestrator components ───────────────────────────────────────────────
  sl.registerLazySingleton<IntentAnalyzer>(() => const IntentAnalyzer());
  sl.registerLazySingleton<ExecutionEngine>(() => createExecutor());

  // ── Planning engine (TaskWeaver-inspired) ─────────────────────────────────
  sl.registerLazySingleton<PlannerService>(
    () => PlannerService(inferenceService: sl<InferenceService>()),
  );
  sl.registerLazySingleton<SequentialPlanningStrategy>(
    () => SequentialPlanningStrategy(plannerService: sl<PlannerService>()),
  );
  sl.registerLazySingleton<CodingAssistantAgentImpl>(
    () => CodingAssistantAgentImpl(
      plannerService: sl<PlannerService>(),
      inferenceService: sl<InferenceService>(),
    ),
  );

  // ── Repositories ───────────────────────────────────────────────────────────
  sl.registerLazySingleton<AiRepository>(
    () => AiRepositoryImpl(
      openAiDataSource: sl<OpenAiDataSource>(),
      geminiDataSource: sl<GeminiDataSource>(),
      claudeDataSource: sl<ClaudeDataSource>(),
      grokDataSource: sl<GrokDataSource>(),
      copilotDataSource: sl<CopilotDataSource>(),
    )..setProvider(sl<AiRuntimeSettingsService>().activeProvider),
  );
  sl.registerLazySingleton<CloudRuntimeProvider>(
    () => CloudRuntimeProvider(
      sendQuery: (provider, request) async {
        final result = await sl<AiRepository>().sendQueryWithProvider(provider, request);
        return result.fold(
          (failure) => throw failure,
          (response) => response,
        );
      },
      supportedProviders: () => sl<AiRepository>().supportedProviders,
      isProviderAvailable: (provider) => sl<AiRepository>().isProviderAvailable(provider),
      providerDisplayName: ([providerName]) =>
          sl<AiRepository>().providerDisplayName(providerName),
    ),
  );
  sl.registerLazySingleton<InferenceService>(
    () => InferenceService(
      loadSelectedModel: () async {
        final result = await sl<LocalAiRepository>().getSelectedModel();
        // Intentionally degrade to null on selection read failure so runtime
        // falls back to cloud inference without crashing startup/session flows.
        return result.fold((_) => null, (model) => model);
      },
      loadRuntimeMode: () => sl<AiRuntimeSettingsService>().loadRuntimeMode(),
      runtimeProvider: sl<LocalRuntimeProvider>(),
      cloudRuntimeProvider: sl<CloudRuntimeProvider>(),
    ),
  );
  sl.registerLazySingleton<Orchestrator>(
    () => Orchestrator(
      intentAnalyzer: sl<IntentAnalyzer>(),
      executor: sl<ExecutionEngine>(),
      inferenceService: sl<InferenceService>(),
      plannerService: sl<PlannerService>(),
    ),
  );
  sl.registerLazySingleton<ChatRepository>(
    () => ChatRepositoryImpl(
      localDataSource: sl<ChatLocalDataSource>(),
      orchestrator: sl<Orchestrator>(),
    ),
  );

  // ── Use cases ──────────────────────────────────────────────────────────────
  sl.registerLazySingleton(
      () => GetProjectMemories(sl<ProjectMemoryRepository>()));
  sl.registerLazySingleton(
      () => GetLatestProjectMemory(sl<ProjectMemoryRepository>()));
  sl.registerLazySingleton(
      () => SaveProjectMemory(sl<ProjectMemoryRepository>()));
  sl.registerLazySingleton(
      () => UpdateProjectMemory(sl<ProjectMemoryRepository>()));
  sl.registerLazySingleton(
      () => DeleteProjectMemory(sl<ProjectMemoryRepository>()));
  sl.registerLazySingleton(
      () => DeleteAllProjectMemories(sl<ProjectMemoryRepository>()));
  sl.registerLazySingleton(() => SendAiQuery(sl<AiRepository>()));
  sl.registerLazySingleton(() => SendChatMessage(sl<ChatRepository>()));
  sl.registerLazySingleton(() => LoadChatMessages(sl<ChatRepository>()));
  sl.registerLazySingleton(() => PruneChatHistory(sl<ChatRepository>()));

  // ── BLoCs ──────────────────────────────────────────────────────────────────
  sl.registerFactory(
    () => ProjectMemoryBloc(
      getProjectMemories: sl<GetProjectMemories>(),
      getLatestProjectMemory: sl<GetLatestProjectMemory>(),
      saveProjectMemory: sl<SaveProjectMemory>(),
      updateProjectMemory: sl<UpdateProjectMemory>(),
      deleteProjectMemory: sl<DeleteProjectMemory>(),
      deleteAllProjectMemories: sl<DeleteAllProjectMemories>(),
    ),
  );
  sl.registerFactory(
    () => OrchestratorStateEngine(
      chatRepository: sl<ChatRepository>(),
    ),
  );
  sl.registerFactory(
    () => ChatBloc(
      sendChatMessage: sl<SendChatMessage>(),
      loadChatMessages: sl<LoadChatMessages>(),
      pruneChatHistory: sl<PruneChatHistory>(),
    ),
  );
  sl.registerFactory(
    () => OnboardingBloc(
        modelRegistryDataSource: sl<ModelRegistryDataSource>()),
  );
  sl.registerFactory(
    () => ModelDownloadBloc(
      getAvailableModels: sl<GetAvailableModels>(),
      downloadModel: sl<DownloadModel>(),
      importLocalModel: sl<ImportLocalModel>(),
      downloadModelFromUrl: sl<DownloadModelFromUrl>(),
      checkForUpdates: sl<CheckForUpdates>(),
      selectModel: sl<SelectModel>(),
      getSelectedModel: sl<GetSelectedModel>(),
      repository: sl<LocalAiRepository>(),
    ),
  );
}
