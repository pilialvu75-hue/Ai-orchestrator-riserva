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
      'id': 'gemma_2b',
      'displayName': 'Gemma 2B',
      'fileName': 'gemma-2-2b-it-Q4_K_M.gguf',
      'downloadUrl':
          'https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf?download=true',
      'version': '1.0.0',
      'sizeBytes': 1500000000,
      'description': 'Google Gemma 2B – balanced speed and quality',
      'platformTarget': 'all',
    },
    {
      'id': 'phi4_mini',
      'displayName': 'Phi-4 Mini',
      'fileName': 'Phi-4-mini-instruct-Q4_K_M.gguf',
      'downloadUrl':
          'https://huggingface.co/bartowski/Phi-4-mini-instruct-GGUF/resolve/main/Phi-4-mini-instruct-Q4_K_M.gguf?download=true',
      'version': '1.0.0',
      'sizeBytes': 2200000000,
      'description': 'Microsoft Phi-4 Mini – strong reasoning',
      'platformTarget': 'all',
    },
    {
      'id': 'llama_1b',
      'displayName': 'Llama 3.2 1B',
      'fileName': 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      'downloadUrl':
          'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      'version': '1.0.0',
      'sizeBytes': 800000000,
      'description':
          'Meta Llama 3.2 1B – fastest, lowest memory usage',
      'platformTarget': 'all',
    },
    {
      'id': 'deepseek_r1_1_5b',
      'displayName': 'DeepSeek-R1-Distill-Qwen-1.5B',
      'fileName': 'DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf',
      'downloadUrl':
          'https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf?download=true',
      'version': '1.0.0',
      'sizeBytes': 1120000000,
      'description':
          'DeepSeek-R1-Distill-Qwen-1.5B (Q4_K_M) – Coding Specialist · ~1.12 GB · Quantization: Q4_K_M · Android/mobile recommended',
      'platformTarget': 'android',
    },
    {
      'id': 'qwen3_1_7b',
      'displayName': 'Qwen3-1.7B',
      'fileName': 'Qwen3-1.7B-Q4_K_M.gguf',
      'downloadUrl':
          'https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf?download=true',
      'version': '1.0.0',
      'sizeBytes': 1100000000,
      'description':
          'Qwen3-1.7B (Q4_K_M) – Chat Fluida + Orchestrator · ~1.1 GB · Quantization: Q4_K_M · Universal',
      'platformTarget': 'all',
    },
    {
      'id': 'gemma_2_2b_it',
      'displayName': 'Gemma-2-2B-IT',
      'fileName': 'gemma-2-2b-it-Q4_K_M.gguf',
      'downloadUrl':
          'https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf?download=true',
      'version': '1.0.0',
      'sizeBytes': 1710000000,
      'description':
          'Google Gemma-2-2B-IT (Q4_K_M) – Creative Tester / Validator · ~1.71 GB · Quantization: Q4_K_M · Universal',
      'platformTarget': 'all',
    },
    {
      'id': 'deepseek_r1_7b',
      'displayName': 'DeepSeek-R1-Distill-Qwen-7B (PC Only)',
      'fileName': 'DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf',
      'downloadUrl':
          'https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf?download=true',
      'version': '1.0.0',
      'sizeBytes': 4680000000,
      'description':
          'DeepSeek-R1-Distill-Qwen-7B (Q4_K_M) – Reasoning Specialist · ~4.68 GB · Desktop/PC recommended only · Not supported on Android',
      'platformTarget': 'windows',
    },
  ];

  static const int contextWindowMaxMessages = 20;
  static const Duration modelDownloadTimeout = Duration(hours: 2);
  static const String updateManifestUrl =
      'https://raw.githubusercontent.com/pilialvu75-hue/Ai-orchestrator-riserva/main/update/version.json';
  static const String updateGitHubOwner = 'pilialvu75-hue';
  static const String updateGitHubRepo = 'Ai-orchestrator-riserva';
  static const Duration updateCheckInterval = Duration(hours: 12);

  static const String sttDefaultLocaleId = 'en_US';
  static const String sherpaVoiceMethodChannel =
      'com.aiorchestrator/sherpa_onnx_voice';
  static const String sherpaAsrEventChannel =
      'com.aiorchestrator/sherpa_onnx_asr_events';
}
