/// Application-wide constants used by multiple features.
class AppConstants {
  AppConstants._();

  // ── Database ────────────────────────────────────────────────────────────────
  static const String databaseName = 'ai_orchestrator.db';
  static const int databaseVersion = 5;

  // ── Tables ──────────────────────────────────────────────────────────────────
  static const String tableProjectMemory = 'project_memory';
  static const String tableChatHistory = 'chat_history';
  static const String tableUserPreferences = 'user_preferences';
  static const String tableDocumentChunks = 'document_chunks';
  static const String tableSyncChanges = 'sync_changes';

  // ── sync_changes columns ─────────────────────────────────────────────────────
  static const String colSyncId = 'sync_id';
  static const String colSyncCollection = 'collection';
  static const String colSyncKey = 'record_key';
  static const String colSyncValue = 'record_value';
  static const String colSyncHlc = 'hlc';
  static const String colSyncNodeId = 'node_id';
  static const String colSyncApplied = 'applied';

  // ── Sync / P2P constants ─────────────────────────────────────────────────────
  static const int syncDefaultPort = 47847;
  static const int syncDiscoveryPort = 47848;
  static const String syncDiscoveryMulticast = '239.255.47.47';
  static const Duration syncDiscoveryInterval = Duration(seconds: 10);
  static const Duration syncConnectionTimeout = Duration(seconds: 5);

  // ── project_memory columns ──────────────────────────────────────────────────
  static const String colId = 'id';
  static const String colMasterGoal = 'master_goal';
  static const String colCurrentContext = 'current_context';
  static const String colLastCodeSnippet = 'last_code_snippet';
  static const String colTimestamp = 'timestamp';

  // ── chat_history columns ─────────────────────────────────────────────────────
  static const String colSessionId = 'session_id';
  static const String colRole = 'role';
  static const String colContent = 'content';
  static const String colProvider = 'provider';
  static const String colAttachments = 'attachments_json';

  // ── user_preferences columns ─────────────────────────────────────────────────
  static const String colPrefKey = 'pref_key';
  static const String colPrefValue = 'pref_value';

  // ── document_chunks columns ──────────────────────────────────────────────────
  static const String colDocumentId = 'document_id';
  static const String colDocumentPath = 'document_path';
  static const String colDocumentTitle = 'document_title';
  static const String colChunkIndex = 'chunk_index';
  static const String colChunkText = 'chunk_text';
  static const String colVectorJson = 'vector_json';

  // ── Preference keys ──────────────────────────────────────────────────────────
  static const String prefActiveProvider = 'active_ai_provider';
  static const String prefThemeMode = 'theme_mode';
  static const String prefSelectedModel = 'selected_model';
  static const String prefOnboardingDone = 'onboarding_done';
  static const String prefUserName = 'user_name';
  static const String prefUserBirthDate = 'user_birth_date';
  static const String prefUserProfileData = 'user_profile_data';
  static const String prefDirectionalPrompt = 'directional_prompt';
  static const String prefLanguageOverride = 'language_override';
  static const String prefAiMode = 'ai_mode';
  static const String prefReleaseChannel = 'release_channel';
  static const String prefDeveloperMode = 'developer_mode';

  // ── AI providers ─────────────────────────────────────────────────────────────
  static const String openAiBaseUrl = 'https://api.openai.com/v1';
  static const String geminiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta';
  static const String claudeBaseUrl = 'https://api.anthropic.com/v1';
  static const String grokBaseUrl = 'https://api.x.ai/v1';
  static const String copilotChatUrl =
      'https://api.githubcopilot.com/chat/completions';

  // ── Android / Bixby Intent actions ──────────────────────────────────────────
  static const String intentActionShareContext =
      'com.aiorchestrator.SHARE_CONTEXT';
  static const String intentActionReceiveCode =
      'com.aiorchestrator.RECEIVE_CODE';
  static const String intentBixbyAlarm =
      'com.samsung.android.app.alarm.ADD_ALARM';
  static const String intentBixbyAirplaneMode =
      'android.settings.AIRPLANE_MODE_SETTINGS';
  static const String intentBixbyWifi = 'android.settings.WIFI_SETTINGS';
  static const String intentBixbyRoutine =
      'com.samsung.android.bixby.routines.ACTION_RUN_ROUTINE';

  // ── Cache management ─────────────────────────────────────────────────────────
  static const int chatHistoryMaxAgeDays = 30;
  static const int chatHistoryMaxRows = 500;

  // ── Local AI model definitions ────────────────────────────────────────────
  /// Version-manifest endpoint (replace with your actual hosting URL).
  static const String modelVersionManifestUrl =
      'https://raw.githubusercontent.com/pilialvu75-hue/Ai-orchestrator-riserva/main/models/manifest.json';

  /// Platform target values used in model definitions.
  static const String platformAndroid = 'android';
  static const String platformWindows = 'windows';
  static const String platformAll = 'all';

  static const List<Map<String, dynamic>> availableModels = [
    {
      'id': 'llama_1b',
      'displayName': 'TinyLlama 1.1B Chat',
      'fileName': 'tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf',
      'downloadUrl':
          'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf?download=true',
      'version': '1.0.0',
      'sizeBytes': 669000000,
      'description':
          'TinyLlama 1.1B Chat (Q4_K_M) – minimal verification model for Android local-runtime proof-of-life.',
      'platformTarget': 'android',
    },
  ];

  static const int contextWindowMaxMessages = 20;
  static const Duration modelDownloadTimeout = Duration(hours: 2);
  static const String updateManifestUrl =
      'https://raw.githubusercontent.com/pilialvu75-hue/Ai-orchestrator-riserva/main/update/version.json';
  static const String updateGitHubOwner = 'pilialvu75-hue';
  static const String updateGitHubRepo = 'Ai-orchestrator-riserva';
  static const Duration updateCheckInterval = Duration(hours: 12);

  // Primary locale for STT recognition output post-processing.
  // Note: the selected streaming transducer (Zipformer EN-2023-06-26) is
  // English-primary.  No public streaming Zipformer/transducer model covering
  // Italian + French + English exists as of mid-2025.  Italian and French
  // vocabulary embedded in English speech (code-switching) is handled via
  // VoiceTextNormalizer and hotwords if needed.
  static const String sttDefaultLocaleId = 'en_US';
  // ── Sherpa-ONNX STT runtime hints ──────────────────────────────────────────
  // modelType must match the architecture tag expected by the sherpa-onnx
  // OnlineModelConfig.  'zipformer2' selects the Zipformer2 transducer
  // processing path in the ONNX runtime.
  static const String sttModelType = 'zipformer2';
  static const int sttNumThreads = 2;
  // ── Sherpa-ONNX local model file names ─────────────────────────────────────
  static const String sttEncoderFile = 'encoder.onnx';
  static const String sttDecoderFile = 'decoder.onnx';
  static const String sttJoinerFile = 'joiner.onnx';
  static const String sttTokensFile = 'tokens.txt';
  static const String sttZipformerEnRepository =
      'csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26';
  static const String sttZipformerBaseUrl =
      'https://huggingface.co/$sttZipformerEnRepository/resolve/main';
  static const String llmModelFile = 'gemma-2b-it.onnx';
  static const String ttsModelFile = 'vits-tts-it.onnx';
  static const String ttsLexiconFile = 'vits-tts-lexicon.txt';
  static const String ttsTokensFile = 'vits-tts-tokens.txt';
  static const String sherpaVoiceMethodChannel =
      'com.aiorchestrator/sherpa_onnx_voice';
  static const String sherpaAsrEventChannel =
      'com.aiorchestrator/sherpa_onnx_asr_events';
}
