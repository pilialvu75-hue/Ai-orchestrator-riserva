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

  // ── sync_changes columns ────────────────────────────────────────────────────
  static const String colSyncId = 'sync_id';
  static const String colSyncCollection = 'collection';
  static const String colSyncKey = 'record_key';
  static const String colSyncValue = 'record_value';
  static const String colSyncHlc = 'hlc';
  static const String colSyncNodeId = 'node_id';
  static const String colSyncApplied = 'applied';

  // ── Sync / P2P constants ────────────────────────────────────────────────────
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

  // ── user_preferences columns ────────────────────────────────────────────────
  static const String colPrefKey = 'pref_key';
  static const String colPrefValue = 'pref_value';

  // ── document_chunks columns ─────────────────────────────────────────────────
  static const String colDocumentId = 'document_id';
  static const String colDocumentPath = 'document_path';
  static const String colDocumentTitle = 'document_title';
  static const String colChunkIndex = 'chunk_index';
  static const String colChunkText = 'chunk_text';
  static const String colVectorJson = 'vector_json';

  // ── Preference keys ─────────────────────────────────────────────────────────
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
  static const String prefMemoryWindowProfile = 'memory_window.profile';
  static const String prefMemoryWindowCustomTokenBudget =
      'memory_window.custom_token_budget';
  static const String prefMemoryWindowCustomLineBudget =
      'memory_window.custom_line_budget';
  static const String prefAssistantTextSize = 'chat.assistant_text_size';
  static const String prefLlmRoleBindingPrefix = 'llm.role.binding.';

  // ── AI providers ────────────────────────────────────────────────────────────
  static const String openAiBaseUrl = 'https://api.openai.com/v1';
  static const String geminiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta';
  static const String claudeBaseUrl = 'https://api.anthropic.com/v1';
  static const String grokBaseUrl = 'https://api.x.ai/v1';
  static const String copilotChatUrl =
      'https://api.githubcopilot.com/chat/completions';

  // ── Android / Bixby Intent actions ─────────────────────────────────────────
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

  // ── Cache management ────────────────────────────────────────────────────────
  static const int chatHistoryMaxAgeDays = 30;
  static const int chatHistoryMaxRows = 500;

  // ── Local AI model definitions ─────────────────────────────────────────────
  static const String modelVersionManifestUrl =
      'https://raw.githubusercontent.com/pilialvu75-hue/Ai-orchestrator-riserva/main/models/manifest.json';

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
      'sizeCategory': '1B',
    },
    {
      'id': 'phi3_5_mini',
      'displayName': 'Phi-3.5 Mini Instruct',
      'fileName': 'Phi-3.5-mini-instruct-Q4_K_M.gguf',
      'downloadUrl':
          'https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf',
      'version': '1.0.0',
      'sizeBytes': 2390000000,
      'description':
          'Phi-3.5 Mini Instruct (Q4_K_M) – mobile-friendly 3.5B local model for concise reasoning and tool use.',
      'platformTarget': 'android',
      'sizeCategory': '4B',
    },
  ];

  static const int contextWindowMaxMessages = 20;
  static const Duration modelDownloadTimeout = Duration(hours: 2);

  static const String updateManifestUrl =
      'https://raw.githubusercontent.com/pilialvu75-hue/Ai-orchestrator-riserva/main/update/version.json';

  static const String updateGitHubOwner = 'pilialvu75-hue';
  static const String updateGitHubRepo = 'Ai-orchestrator-riserva';
  static const Duration updateCheckInterval = Duration(hours: 12);

  // ── STT runtime ─────────────────────────────────────────────────────────────
  //
  // Nemotron 3.5 è il modello STT ufficiale del runtime Live.
  // È multilingue e supporta direttamente italiano.
  //
  // Il valore vuoto di sttModelType è intenzionale:
  // Sherpa-ONNX riceve un modello transducer esplicito e non deve
  // essere forzato a Zipformer/Zipformer2.

  static const String sttDefaultLocaleId = 'it_IT';
  static const String sttDefaultLanguage = 'it-IT';
  static const String sttModelType = '';
  static const int sttNumThreads = 2;

  // ── Sherpa-ONNX STT file names ──────────────────────────────────────────────
  //
  // Il pacchetto Nemotron ufficiale contiene:
  //   encoder.int8.onnx
  //   decoder.int8.onnx
  //   joiner.int8.onnx
  //   tokens.txt
  //
  // Il downloader li installa con questi nomi canonici.

  static const String sttEncoderFile = 'encoder.onnx';
  static const String sttDecoderFile = 'decoder.onnx';
  static const String sttJoinerFile = 'joiner.onnx';
  static const String sttTokensFile = 'tokens.txt';

  // ── Sherpa-ONNX STT — Nemotron 3.5 ─────────────────────────────────────────
  static const String sttNemotronRepository =
      'sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11';

  static const String sttNemotronTarUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
      'sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11.tar.bz2';

  // Fallback utilizzato solo quando il server non fornisce Content-Length.
  // Il pacchetto reale è circa 650 MB.
  static const int sttNemotronTarExpectedBytes =
      700 * 1024 * 1024;

  // ── Sherpa-ONNX TTS file names (Piper Paola) ────────────────────────────────
  static const String ttsModelFile = 'it_IT-paola-medium.onnx';
  static const String ttsTokensFile = 'tokens.txt';
  static const String ttsEspeakDataDir = 'espeak-ng-data';

  // ── Sherpa-ONNX TTS download ────────────────────────────────────────────────
  static const String ttsPaolaRepository =
      'vits-piper-it_IT-paola-medium';

  static const String ttsPaolaTarUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/'
      'vits-piper-it_IT-paola-medium.tar.bz2';

  static const int ttsPaolaTarExpectedBytes =
      63 * 1024 * 1024;

  // ── Voice ───────────────────────────────────────────────────────────────────
  static const String ttsDefaultLanguage = 'it-IT';

  // ── Sherpa-ONNX channels ────────────────────────────────────────────────────
  static const String sherpaVoiceMethodChannel =
      'com.aiorchestrator/sherpa_onnx_voice';

  static const String sherpaAsrEventChannel =
      'com.aiorchestrator/sherpa_onnx_asr_events';

  // ── Voice model storage ─────────────────────────────────────────────────────
  static const String voiceModelsDirectory = 'voice_models';
  static const String sttModelsDirectory = 'stt';
  static const String ttsModelsDirectory = 'tts';

  // ── Voice model archive markers ─────────────────────────────────────────────
  static const String sttModelArchiveMarker =
      'stt_nemotron_multilingual';

  static const String ttsModelArchiveMarker =
      'tts_paola_italian';

  // ── Audio ───────────────────────────────────────────────────────────────────
  static const int voiceSampleRate = 16000;
  static const int voiceChannels = 1;

  // ── Voice endpointing ───────────────────────────────────────────────────────
  static const double sttRule1MinTrailingSilence = 2.4;
  static const double sttRule2MinTrailingSilence = 1.4;
  static const double sttRule3MinUtteranceLength = 20.0;
}
