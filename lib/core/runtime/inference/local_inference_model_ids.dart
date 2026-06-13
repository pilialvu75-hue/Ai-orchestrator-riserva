class LocalInferenceModelIds {
  LocalInferenceModelIds._();

  static const String llama1b = 'llama_1b';
  static const String gemma2b = 'gemma_2b';
  static const String gemma2_2bIt = 'gemma_2_2b_it';
  static const String deepSeekR1_1_5b = 'deepseek_r1_1_5b';
  static const String qwen3_1_7b = 'qwen3_1_7b';
  static const String deepSeekR1_7b = 'deepseek_r1_7b';

  static final Set<String> llama3ChatTemplateModels = {llama1b};
  static final Set<String> qwenChatTemplateModels = {
    deepSeekR1_1_5b,
    qwen3_1_7b,
    deepSeekR1_7b,
  };
  static final Set<String> qwen3ThinkingModels = {qwen3_1_7b};
  static final Set<String> gemmaChatTemplateModels = {gemma2_2bIt};

  /// Risolve il template corretto per un modelId arbitrario (inclusi
  /// modelli importati dall'utente con nomi liberi).
  /// Priorità: set esatto → pattern nome → fallback plain.
  static String resolveTemplate(String modelId) {
    final id = modelId.trim().toLowerCase();

    // Controllo nei set registrati (match esatto)
    if (llama3ChatTemplateModels.contains(modelId)) return 'llama3';
    if (qwenChatTemplateModels.contains(modelId)) return 'qwen';
    if (gemmaChatTemplateModels.contains(modelId)) return 'gemma';

    // Pattern matching per modelli importati dall'utente
    if (_matchesLlama3(id)) return 'llama3';
    if (_matchesQwen(id)) return 'qwen';
    if (_matchesGemma(id)) return 'gemma';

    return 'plain'; // fallback
  }

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

  static bool _matchesGemma(String id) {
    return id.contains('gemma');
  }

  static bool isQwen3Thinking(String modelId) {
    final id = modelId.trim().toLowerCase();
    return qwen3ThinkingModels.contains(modelId) ||
        id.contains('qwen3') ||
        (id.contains('deepseek') && id.contains('r1'));
  }

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
    }
  }
}
