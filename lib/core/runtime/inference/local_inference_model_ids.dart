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

  // ── Nuove costanti Phi-3.5-mini ────────────────────────────────────────────
  static const String phi3_5_mini = 'phi3_5_mini';

  // ── Set di appartenenza per match esatto ─────────────────────────────────

  /// Modelli che usano il template Llama 3 Instruct
  /// (<|begin_of_text|> / <|start_header_id|> / <|eot_id|>).
  static final Set<String> llama3ChatTemplateModels = {
    llama1b,
  };

  /// Modelli che usano il template ChatML / Qwen
  /// (<|im_start|> / <|im_end|>).
  static final Set<String> qwenChatTemplateModels = {
    deepSeekR1_1_5b,
    qwen3_1_7b,
    deepSeekR1_7b,
    phi3_5_mini, // <- Aggiunto Phi-3.5-mini
  };

  /// Sottoinsieme di [qwenChatTemplateModels] che supportano la direttiva
  /// Qwen3 `/no_think` per sopprimere il chain-of-thought.
  /// Necessario su Android dove il budget token è troppo stretto per
  /// accomodare i thinking token prima della risposta finale.
  static final Set<String> qwen3ThinkingModels = {
    qwen3_1_7b,
    // Phi-3.5-mini NON supporta /no_think, quindi non lo aggiungo
  };

  static final Set<String> gemmaChatTemplateModels = {
    gemma2_2bIt,
  };

  // ── Risoluzione template ──────────────────────────────────────────────────

  /// Risolve il template corretto per un modelId arbitrario.
  ///
  /// Priorità:
  /// 1. Match esatto nei set registrati (costanti + registerModel)
  /// 2. Pattern matching sul nome (modelli importati dall'utente)
  /// 3. Fallback 'plain'
  ///
  /// Questo permette a modelli importati con nomi liberi come
  /// "Llama-3.2-1B-Instruct-Q4_K_M" o "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M"
  /// di ricevere il template corretto senza registrazione manuale.
  static String resolveTemplate(String modelId) {
    // 1. Match esatto nei set
    if (llama3ChatTemplateModels.contains(modelId)) return 'llama3';
    if (qwenChatTemplateModels.contains(modelId)) return 'qwen';
    if (gemmaChatTemplateModels.contains(modelId)) return 'gemma';

    // 2. Pattern matching (case-insensitive) per modelli importati
    final id = modelId.trim().toLowerCase();
    if (_matchesLlama3(id)) return 'llama3';
    if (_matchesQwen(id)) return 'qwen';
    if (_matchesGemma(id)) return 'gemma';

    // 3. Fallback plain text
    return 'plain';
  }

  /// Restituisce true se il modello supporta la direttiva /no_think.
  /// Solo Qwen3 nativo supporta /no_think.
  /// DeepSeek-R1-Distill e Phi-3 non lo supportano e corrompono l'output.
  static bool isQwen3Thinking(String modelId) {
    if (qwen3ThinkingModels.contains(modelId)) return true;
    final id = modelId.trim().toLowerCase();
    // Solo Qwen3 nativo supporta /no_think.
    // DeepSeek-R1-Distill e Phi-3 non lo supportano e corrompono l'output.
    return id.contains('qwen3') &&!id.contains('phi');
  }

  // ── Pattern matching privato ──────────────────────────────────────────────

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

  // ── Registrazione dinamica ────────────────────────────────────────────────

  /// Registra un modello importato associandolo a un template specifico.
  ///
  /// Utile per modelli con nomi non riconoscibili dai pattern automatici.
  /// Esempio:
  /// ```dart
  /// LocalInferenceModelIds.registerModel(
  /// 'mio_modello_custom',
  /// template: 'llama3',
  /// );
  /// ```
  static void registerModel(
    String modelId, {
    required String template,
    bool supportsNoThink = false,
  }) {
    switch (template.toLowerCase()) {
      case 'llama3':
        llama3ChatTemplateModels.add(modelId);
        break;
      case 'qwen':
        qwenChatTemplateModels.add(modelId);
        if (supportsNoThink) qwen3ThinkingModels.add(modelId);
        break;
      case 'gemma':
        gemmaChatTemplateModels.add(modelId);
        break;
      default:
        // Template non riconosciuto: nessuna azione.
        // resolve
