class LocalInferenceModelIds {
  LocalInferenceModelIds._();

  // ── Costanti originali (invariate per retrocompatibilità) ─────────────────
  static const String llama1b = 'llama_1b';
  static const String gemma2b = 'gemma_2b';
  static const String gemma2_2bIt = 'gemma_2b_it';
  static const String deepSeekR1_1_5b = 'deepseek_r1_1_5b';
  static const String qwen3_1_7b = 'qwen3_1_7b';

  /// Desktop/PC-only model (non nella lista Android-safe).
  static const String deepSeekR1_7b = 'deepseek_r1_7b';

  // ── Nuove costanti Phi-3.5-mini ────────────────────────────────────────────
  static const String phi35Mini = 'phi3_5_mini';

  @Deprecated('Usa phi35Mini per rispettare lo stile lowerCamelCase')
  static const String phi3_5_mini = phi35Mini;

  // ── Set di appartenenza per match esatto ─────────────────────────────────

  /// Modelli che usano il template Llama 3 Instruct
  /// (<|begin_of_text|> / <|start_header_id|> / <|eot_id|>).
  ///
  /// ATTENZIONE:
  /// TinyLlama 1.1B Chat NON appartiene a questo gruppo.
  static final Set<String> llama3ChatTemplateModels = <String>{};

  /// TinyLlama 1.1B Chat usa il formato chat stile Zephyr:
  ///
  /// <|system|>
  /// <|user|>
  /// <|assistant|>
  /// </s>
  ///
  /// Il modelId storico `llama_1b` identifica proprio TinyLlama
  /// nel manifest Android.
  static final Set<String> zephyrChatTemplateModels = {
    llama1b,
  };

  /// Modelli DeepSeek-R1 (e distillati) che usano il proprio template
  /// conversazionale DeepSeek.
  ///
  /// NON devono essere classificati come Qwen/ChatML, anche se i modelli
  /// DeepSeek-R1-Distill-Qwen sono basati sull'architettura Qwen.
  static final Set<String> deepseekChatTemplateModels = {
    deepSeekR1_1_5b,
    deepSeekR1_7b,
  };

  /// Modelli che usano il template ChatML / Qwen
  /// (<|im_start|> / <|im_end|>).
  static final Set<String> qwenChatTemplateModels = {
    qwen3_1_7b,
  };

  /// Sottoinsieme di [qwenChatTemplateModels] che supportano la direttiva
  /// Qwen3 `/no_think` per sopprimere il chain-of-thought.
  /// Necessario su Android dove il budget token è troppo stretto per
  /// accomodare i thinking token prima della risposta finale.
  static final Set<String> qwen3ThinkingModels = {
    qwen3_1_7b,
    // Phi-3.5-mini NON supporta /no_think
  };

  static final Set<String> gemmaChatTemplateModels = {
    gemma2_2bIt,
  };

  /// Modelli che usano il template Phi-3 / Phi-3.5.
  static final Set<String> phi3ChatTemplateModels = {
    phi35Mini,
  };

  // ── Risoluzione template ──────────────────────────────────────────────────

  /// Risolve il template corretto per un modelId arbitrario.
  ///
  /// Priorità:
  /// 1. Match esatto nei set registrati
  /// 2. Pattern matching sul nome
  /// 3. Fallback 'plain'
  static String resolveTemplate(String modelId) {
    // 1. Match esatto nei set

    // IMPORTANTISSIMO:
    // TinyLlama 1.1B Chat -> Zephyr-style template.
    if (zephyrChatTemplateModels.contains(modelId)) {
      return 'zephyr';
    }

    if (llama3ChatTemplateModels.contains(modelId)) {
      return 'llama3';
    }

    // DeepSeek deve essere risolto prima di Qwen.
    //
    // I modelli DeepSeek-R1-Distill-Qwen contengono "Qwen" nel nome
    // del modello, ma NON devono essere trattati come Qwen ChatML.
    if (deepseekChatTemplateModels.contains(modelId)) {
      return 'deepseek';
    }

    if (qwenChatTemplateModels.contains(modelId)) {
      return 'qwen';
    }

    if (gemmaChatTemplateModels.contains(modelId)) {
      return 'gemma';
    }

    if (phi3ChatTemplateModels.contains(modelId)) {
      return 'phi3';
    }

    // 2. Pattern matching (case-insensitive)
    final id = modelId.trim().toLowerCase();

    // TinyLlama deve essere intercettato PRIMA di llama3.
    if (_matchesTinyLlama(id)) {
      return 'zephyr';
    }

    if (_matchesPhi(id)) {
      return 'phi3';
    }

    if (_matchesLlama3(id)) {
      return 'llama3';
    }

    // DeepSeek prima di Qwen: un nome/path può contenere sia
    // "deepseek" sia "qwen".
    if (_matchesDeepSeek(id)) {
      return 'deepseek';
    }

    if (_matchesQwen(id)) {
      return 'qwen';
    }

    if (_matchesGemma(id)) {
      return 'gemma';
    }

    // 3. Fallback plain text
    return 'plain';
  }

  /// Restituisce true se il modello supporta la direttiva /no_think.
  ///
  /// Solo Qwen3 nativo supporta /no_think.
  /// DeepSeek-R1-Distill e Phi-3 non lo supportano.
  static bool isQwen3Thinking(String modelId) {
    if (qwen3ThinkingModels.contains(modelId)) {
      return true;
    }

    final id = modelId.trim().toLowerCase();

    return id.contains('qwen3') && !id.contains('phi');
  }

  // ── Pattern matching privato ──────────────────────────────────────────────

  static bool _matchesTinyLlama(String id) {
    return id.contains('tinyllama') ||
        id.contains('tiny-llama');
  }

  static bool _matchesLlama3(String id) {
    return id.contains('llama-3') ||
        id.contains('llama3') ||
        id.contains('llama_3') ||
        id.contains('meta-llama');
  }

  static bool _matchesDeepSeek(String id) {
    return id.contains('deepseek');
  }

  static bool _matchesQwen(String id) {
    // DeepSeek è gestito da _matchesDeepSeek() ed è valutato prima.
    return id.contains('qwen') ||
        id.contains('mistral');
  }

  static bool _matchesGemma(String id) {
    return id.contains('gemma');
  }

  static bool _matchesPhi(String id) {
    return id.contains('phi-3') ||
        id.contains('phi3');
  }

  // ── Registrazione dinamica ────────────────────────────────────────────────

  /// Registra un modello importato associandolo a un template specifico.
  ///
  /// Utile per modelli con nomi non riconoscibili dai pattern automatici.
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
        if (supportsNoThink) {
          qwen3ThinkingModels.add(modelId);
        }
        break;

      case 'deepseek':
        deepseekChatTemplateModels.add(modelId);
        break;

      case 'gemma':
        gemmaChatTemplateModels.add(modelId);
        break;

      case 'phi3':
        phi3ChatTemplateModels.add(modelId);
        break;

      case 'zephyr':
        zephyrChatTemplateModels.add(modelId);
        break;

      default:
        // Template non riconosciuto:
        // resolveTemplate() userà il pattern matching
        // o il fallback plain.
        break;
    }
  }

  // ── Temperatura automatica ────────────────────────────────────────────────

  /// Temperatura base usata da AiRuntimeSettingsService per config automatica.
  /// I metadati META nel prompt possono sovrascrivere questo valore
  /// nel runtime FFI.
  static double temperatureForModel(String? modelId) {
    if (modelId == null || modelId.trim().isEmpty) {
      return 0.5;
    }

    final id = modelId.trim().toLowerCase();

    // TinyLlama / Llama 1B
    if (id.contains('llama') && id.contains('1b')) {
      return 0.5;
    }

    // Phi-3.5-mini
    if (id.contains('phi-3.5') ||
        id.contains('phi3_5') ||
        id.contains('phi35mini')) {
      return 0.5;
    }

    // Qwen / DeepSeek
    if (id.contains('qwen') ||
        id.contains('deepseek')) {
      return 0.5;
    }

    // Gemma
    if (id.contains('gemma')) {
      return 0.5;
    }

    return 0.5;
  }
}
