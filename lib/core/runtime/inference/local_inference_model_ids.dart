class LocalInferenceModelIds {
  LocalInferenceModelIds._();

  // ===========================================================================
  // MODEL IDS — COMPATIBILITÀ STORICA
  // ===========================================================================

  static const String llama1b = 'llama_1b';
  static const String gemma2b = 'gemma_2b';
  static const String gemma2_2bIt = 'gemma_2b_it';

  static const String deepSeekR1_1_5b = 'deepseek_r1_1_5b';
  static const String deepSeekR1_7b = 'deepseek_r1_7b';

  static const String qwen3_1_7b = 'qwen3_1_7b';

  static const String phi35Mini = 'phi3_5_mini';

  @Deprecated('Usa phi35Mini')
  // ignore: constant_identifier_names, legacy public alias kept for compatibility
  static const String phi3_5_mini = phi35Mini;

  // ===========================================================================
  // MODEL FAMILY IDS
  //
  // La famiglia determina il template conversazionale.
  //
  // La dimensione del modello NON deve determinare il template.
  //
  // Questo permette di supportare in futuro:
  //
  //   1.5B / 3B / 4B / 7B / 9B / 14B / 32B / 70B / ...
  //
  // senza creare un nuovo template per ogni dimensione.
  // ===========================================================================

  static const String familyDeepSeek = 'deepseek';
  static const String familyQwen = 'qwen';
  static const String familyLlama = 'llama';
  static const String familyGemma = 'gemma';
  static const String familyPhi = 'phi3';
  static const String familyMistral = 'mistral';

  // ===========================================================================
  // TEMPLATE IDS
  //
  // Ogni famiglia avrà il proprio template dedicato in
  // local_prompt_templates.dart.
  // ===========================================================================

  static const String templateDeepSeek = 'deepseek';
  static const String templateQwen = 'qwen3';
  static const String templateLlama = 'llama3';
  static const String templateGemma = 'gemma';
  static const String templatePhi = 'phi3';
  static const String templateMistral = 'mistral';

  /// Template legacy per TinyLlama / Zephyr.
  ///
  /// Non viene eliminato perché `llama_1b` identifica storicamente
  /// TinyLlama nel manifest Android.
  static const String templateZephyr = 'zephyr';

  // ===========================================================================
  // MODELLI PER FAMIGLIA
  // ===========================================================================

  /// DeepSeek-R1 e DeepSeek-R1-Distill.
  ///
  /// IMPORTANTE:
  /// DeepSeek-R1-Distill-Qwen NON viene classificato come Qwen
  /// solamente perché l'architettura sottostante è Qwen.
  static final Set<String> deepseekChatTemplateModels = {
    deepSeekR1_1_5b,
    deepSeekR1_7b,
  };

  /// Qwen3 nativo.
  static final Set<String> qwenChatTemplateModels = {
    qwen3_1_7b,
  };

  /// Llama 3/3.x.
  ///
  /// Rimane vuoto per i modelId storici finché non registriamo
  /// esplicitamente i modelli Llama moderni.
  static final Set<String> llamaChatTemplateModels = <String>{};

  /// Compatibilità con il vecchio nome utilizzato da
  /// local_runtime_provider.dart e da eventuale codice legacy.
  ///
  /// IMPORTANTE:
  /// Questo è lo stesso Set di [llamaChatTemplateModels].
  static final Set<String> llama3ChatTemplateModels =
      llamaChatTemplateModels;

  /// Gemma.
  static final Set<String> gemmaChatTemplateModels = {
    gemma2b,
    gemma2_2bIt,
  };

  /// Phi-3 / Phi-3.5.
  static final Set<String> phiChatTemplateModels = {
    phi35Mini,
  };

  /// Compatibilità con il vecchio nome utilizzato da
  /// local_runtime_provider.dart e da eventuale codice legacy.
  ///
  /// Questo è lo stesso Set di [phiChatTemplateModels].
  static final Set<String> phi3ChatTemplateModels =
      phiChatTemplateModels;

  /// Mistral.
  ///
  /// Predisposto per i modelli Mistral GGUF futuri.
  static final Set<String> mistralChatTemplateModels = <String>{};

  // ===========================================================================
  // LEGACY / SPECIAL TEMPLATE MODELS
  // ===========================================================================

  /// TinyLlama 1.1B Chat.
  ///
  /// Il modelId storico `llama_1b` identifica TinyLlama nel manifest Android.
  ///
  /// NON deve essere trattato come Llama 3.
  static final Set<String> zephyrChatTemplateModels = {
    llama1b,
  };

  // ===========================================================================
  // QWEN3 THINKING
  // ===========================================================================

  /// Modelli Qwen3 che supportano `/no_think`.
  ///
  /// DeepSeek-R1-Distill e Phi-3 NON vengono inseriti qui.
  static final Set<String> qwen3ThinkingModels = {
    qwen3_1_7b,
  };

  // ===========================================================================
  // TEMPLATE RESOLUTION
  // ===========================================================================

  /// Risolve il template corretto per un modelId.
  ///
  /// Ordine:
  ///
  /// 1. Match esatto
  /// 2. Modelli speciali legacy
  /// 3. Pattern matching
  /// 4. Fallback plain
  ///
  /// La priorità DeepSeek > Qwen è intenzionale:
  ///
  /// DeepSeek-R1-Distill-Qwen
  ///
  /// contiene "qwen" nel nome ma non deve essere trattato come Qwen3.
  static String resolveTemplate(String modelId) {
    final exactId = modelId.trim();

    // -------------------------------------------------------------------------
    // Match esatto
    // -------------------------------------------------------------------------

    if (zephyrChatTemplateModels.contains(exactId)) {
      return templateZephyr;
    }

    if (deepseekChatTemplateModels.contains(exactId)) {
      return templateDeepSeek;
    }

    if (qwenChatTemplateModels.contains(exactId)) {
      return templateQwen;
    }

    if (llamaChatTemplateModels.contains(exactId)) {
      return templateLlama;
    }

    if (gemmaChatTemplateModels.contains(exactId)) {
      return templateGemma;
    }

    if (phiChatTemplateModels.contains(exactId)) {
      return templatePhi;
    }

    if (mistralChatTemplateModels.contains(exactId)) {
      return templateMistral;
    }

    // -------------------------------------------------------------------------
    // Pattern matching
    // -------------------------------------------------------------------------

    final id = exactId.toLowerCase();

    // TinyLlama deve avere precedenza assoluta.
    if (_matchesTinyLlama(id)) {
      return templateZephyr;
    }

    // DeepSeek PRIMA di Qwen.
    if (_matchesDeepSeek(id)) {
      return templateDeepSeek;
    }

    if (_matchesQwen(id)) {
      return templateQwen;
    }

    if (_matchesLlama(id)) {
      return templateLlama;
    }

    if (_matchesGemma(id)) {
      return templateGemma;
    }

    if (_matchesPhi(id)) {
      return templatePhi;
    }

    if (_matchesMistral(id)) {
      return templateMistral;
    }

    return 'plain';
  }

  // ===========================================================================
  // FAMILY RESOLUTION
  // ===========================================================================

  /// Restituisce la famiglia logica del modello.
  ///
  /// famiglia != template != dimensione != piattaforma
  ///
  /// In questo modo l'architettura futura può scegliere il modello migliore
  /// per ruolo/hardware senza modificare il sistema dei prompt.
  static String resolveFamily(String modelId) {
    final template = resolveTemplate(modelId);

    switch (template) {
      case templateDeepSeek:
        return familyDeepSeek;

      case templateQwen:
        return familyQwen;

      case templateLlama:
        return familyLlama;

      case templateGemma:
        return familyGemma;

      case templatePhi:
        return familyPhi;

      case templateMistral:
        return familyMistral;

      case templateZephyr:
        // TinyLlama appartiene logicamente alla famiglia Llama,
        // anche se utilizza un template legacy differente.
        return familyLlama;

      default:
        return 'unknown';
    }
  }

  // ===========================================================================
  // QWEN3 THINKING
  // ===========================================================================

  /// Indica se il modello supporta `/no_think`.
  static bool isQwen3Thinking(String modelId) {
    final exactId = modelId.trim();

    if (qwen3ThinkingModels.contains(exactId)) {
      return true;
    }

    final id = exactId.toLowerCase();

    return id.contains('qwen3') &&
        !id.contains('deepseek') &&
        !id.contains('phi');
  }

  // ===========================================================================
  // PATTERN MATCHING
  // ===========================================================================

  static bool _matchesTinyLlama(String id) {
    return id.contains('tinyllama') ||
        id.contains('tiny-llama');
  }

  static bool _matchesDeepSeek(String id) {
    return id.contains('deepseek');
  }

  static bool _matchesQwen(String id) {
    // DeepSeek viene valutato prima.
    return id.contains('qwen');
  }

  static bool _matchesLlama(String id) {
    return id.contains('llama-3') ||
        id.contains('llama3') ||
        id.contains('llama_3') ||
        id.contains('meta-llama');
  }

  static bool _matchesGemma(String id) {
    return id.contains('gemma');
  }

  static bool _matchesPhi(String id) {
    return id.contains('phi-3') ||
        id.contains('phi3');
  }

  static bool _matchesMistral(String id) {
    return id.contains('mistral') ||
        id.contains('mixtral');
  }

  // ===========================================================================
  // REGISTRAZIONE DINAMICA
  // ===========================================================================

  /// Registra un nuovo modello associandolo esplicitamente a una famiglia/
  /// template.
  ///
  /// Questo è il meccanismo che useremo quando arriveranno nuovi GGUF:
  ///
  ///   registerModel(
  ///     'nuovo_modello_9b',
  ///     template: templateQwen,
  ///   );
  ///
  /// Non sarà necessario modificare il resolver.
  static void registerModel(
    String modelId, {
    required String template,
    bool supportsNoThink = false,
  }) {
    final normalizedTemplate = template.trim().toLowerCase();

    switch (normalizedTemplate) {
      case templateDeepSeek:
        deepseekChatTemplateModels.add(modelId);
        break;

      case templateQwen:
        qwenChatTemplateModels.add(modelId);

        if (supportsNoThink) {
          qwen3ThinkingModels.add(modelId);
        }
        break;

      case templateLlama:
        llamaChatTemplateModels.add(modelId);
        break;

      case templateGemma:
        gemmaChatTemplateModels.add(modelId);
        break;

      case templatePhi:
        phiChatTemplateModels.add(modelId);
        break;

      case templateMistral:
        mistralChatTemplateModels.add(modelId);
        break;

      case templateZephyr:
        zephyrChatTemplateModels.add(modelId);
        break;

      default:
        // Template sconosciuto: non registrare il modello.
        break;
    }
  }

  // ===========================================================================
  // TEMPERATURE
  // ===========================================================================

  /// Temperatura base utilizzata da AiRuntimeSettingsService.
  ///
  /// La configurazione META/runtime può eventualmente sovrascriverla.
  static double temperatureForModel(String? modelId) {
    if (modelId == null || modelId.trim().isEmpty) {
      return 0.5;
    }

    final family = resolveFamily(modelId);

    switch (family) {
      case familyDeepSeek:
        return 0.5;

      case familyQwen:
        return 0.5;

      case familyLlama:
        return 0.5;

      case familyGemma:
        return 0.5;

      case familyPhi:
        return 0.5;

      case familyMistral:
        return 0.5;

      default:
        return 0.5;
    }
  }
}
