class LocalInferenceModelIds {
  LocalInferenceModelIds._();

  // ── Costanti originali (invariate per retrocompatibilità) ─────────────────
  static const String llama1b = 'llama_1b';
  static const String gemma2b = 'gemma_2b';
  static const String gemma2_2bIt = 'gemma_2_2b_it';
  static const String deepSeekR1_1_5b = 'deepseek_r1_1_5b';
  static const String qwen3_1_7b = 'qwen3_1_7b';

  /// Desktop/PC-only model (non nella lista Android-safe).
  static const String deepSeekR1_7b = 'deepseek_r1_7b';

  // ── Set di appartenenza per match esatto ─────────────────────────────────

  static final Set<String> llama3ChatTemplateModels = {llama1b};

  static final Set<String> qwenChatTemplateModels = {
    deepSeekR1_1_5b,
    qwen3_1_7b,
    deepSeekR1_7b,
  };

  static final Set<String> qwen3ThinkingModels = {qwen3_1_7b};

  static final Set<String> gemmaChatTemplateModels = {gemma2_2bIt};

  // ── Risoluzione template ──────────────────────────────────────────────────

  /// Risolve il template corretto per un modelId arbitrario.
  ///
  /// Priorità:
  ///   1. Match esatto nei set registrati
  ///   2. Pattern matching sul nome (modelli importati dall'utente)
  ///   3. Fallback 'plain'
  ///
  /// TinyLlama viene controllato PRIMA di Llama3 perché il suo nome
  /// contiene "llama" ma usa il template Zephyr, non Llama3 Instruct.
  static String resolveTemplate(String modelId) {
    // 1. Match esatto nei set
    if (llama3ChatTemplateModels.contains(modelId)) return 'llama3';
    if (qwenChatTemplateModels.contains(modelId)) return 'qwen';
    if (gemmaChatTemplateModels.contains(modelId)) return 'gemma';

    // 2. Pattern matching (case-insensitive) per modelli importati
    final id = modelId.trim().toLowerCase();
    if (_matchesTinyLlama(id)) return 'zephyr';
    if (_matchesLlama3(id)) return 'llama3';
    if (_matchesQwen(id)) return 'qwen';
    if (_matchesGemma(id)) return 'gemma';

    // 3. Fallback plain text
    return 'plain';
  }

  static bool isQwen3Thinking(String modelId) {
    if (qwen3ThinkingModels.contains(modelId)) return true;
    final id = modelId.trim().toLowerCase();
    return id.contains('qwen3') ||
        (id.contains('deepseek') && id.contains('r1'));
  }

  // ── Pattern matching privato ──────────────────────────────────────────────

  /// TinyLlama-1.1B-Chat usa il template Zephyr, non Llama3 Instruct.
  /// Deve essere verificato prima di [_matchesLlama3].
  static bool _matchesTinyLlama(String id) => id.contains('tinyllama');

  static bool _matchesLlama3(String id) {
    return id.contains('llama-3') ||
        id.contains('llama3') ||
        id.contains('llama_3') ||
        id.contains('meta-llama');
  }

  static bool _matchesQwen(String id) {
    return id.contains('deepseek') ||
        id.contains('qwen') ||
        id.contains('mistral') ||
        id.contains('phi-3') ||
        id.contains('phi3');
  }

  static bool _matchesGemma(String id) => id.contains('gemma');

  // ── Registrazione dinamica ────────────────────────────────────────────────

  static void registerModel(
    String modelId, {
    required String template,
    bool supportsNoThink = false,
  }) {
    switch (template.toLowerCase()) {
      case 'llama3':
        llama3ChatTemplateModels.add(modelId);
      case 'qwen':
        qwenChatTemplateModels.add(modelId);
        if (supportsNoThink) qwen3ThinkingModels.add(modelId);
      case 'gemma':
        gemmaChatTemplateModels.add(modelId);
      default:
        break;
    }
  }
}
