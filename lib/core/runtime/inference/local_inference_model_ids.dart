class LocalInferenceModelIds {
  LocalInferenceModelIds._();

  // Costanti originali (rimangono invariate per retrocompatibilità)
  static const String llama1b = 'llama_1b';
  static const String gemma2b = 'gemma_2b';
  static const String gemma2_2bIt = 'gemma_2_2b_it';
  static const String deepSeekR1_1_5b = 'deepseek_r1_1_5b';
  static const String qwen3_1_7b = 'qwen3_1_7b';

  /// Desktop/PC-only model (not in Android-safe list).
  static const String deepSeekR1_7b = 'deepseek_r1_7b';

  // Sostituite le costanti 'const Set' con campi modificabili inizializzati con i valori predefiniti
  
  /// Models that use the Llama 3 Instruct chat template
  /// (<|begin_of_text|> / <|start_header_id|> / <|eot_id|>).
  static final Set<String> llama3ChatTemplateModels = <String>{
    llama1b,
  };

  /// Models that use the ChatML / Qwen template
  /// (<|im_start|> / <|im_end|>).
  static final Set<String> qwenChatTemplateModels = <String>{
    deepSeekR1_1_5b,
    qwen3_1_7b,
    deepSeekR1_7b,
  };

  /// Subset of [qwenChatTemplateModels] that support the Qwen3
  /// `/no_think` directive to suppress chain-of-thought reasoning.
  /// Required on Android where the 128-token budget is too tight
  /// to accommodate thinking tokens before the actual answer.
  static final Set<String> qwen3ThinkingModels = <String>{
    qwen3_1_7b,
  };

  static final Set<String> gemmaChatTemplateModels = <String>{
    gemma2_2bIt,
  };

  // --- METODI PER L'AGGIUNTA DINAMICA ---

  /// Registra un nuovo modello generico associandolo a un template specifico.
  /// Esempio: `LocalInferenceModelIds.registerModel('mio_modello_custom', template: 'qwen');`
  static void registerModel(String modelId, {required String template, bool supportsNoThink = false}) {
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
      case 'gemma':
        gemmaChatTemplateModels.add(modelId);
        break;
      default:
        // Se non corrisponde a nessun template noto, viene comunque registrato ma senza template specifico
        break;
    }
  }
}
