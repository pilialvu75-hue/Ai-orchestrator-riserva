class LocalInferenceModelIds {
  LocalInferenceModelIds._();

  static const String llama1b = 'llama_1b';
  static const String gemma2b = 'gemma_2b';
  static const String gemma2_2bIt = 'gemma_2_2b_it';
  static const String deepSeekR1_1_5b = 'deepseek_r1_1_5b';
  static const String qwen3_1_7b = 'qwen3_1_7b';

  /// Desktop/PC-only model (not in Android-safe list).
  static const String deepSeekR1_7b = 'deepseek_r1_7b';

  /// Models that use the Llama 3 Instruct chat template
  /// (<|begin_of_text|> / <|start_header_id|> / <|eot_id|>).
  static const Set<String> llama3ChatTemplateModels = <String>{
    llama1b,
  };

  /// Models that use the ChatML / Qwen template
  /// (<|im_start|> / <|im_end|>).
  static const Set<String> qwenChatTemplateModels = <String>{
    deepSeekR1_1_5b,
    qwen3_1_7b,
    deepSeekR1_7b,
  };

  /// Subset of [qwenChatTemplateModels] that support the Qwen3
  /// `/no_think` directive to suppress chain-of-thought reasoning.
  /// Required on Android where the 128-token budget is too tight
  /// to accommodate thinking tokens before the actual answer.
  static const Set<String> qwen3ThinkingModels = <String>{
    qwen3_1_7b,
  };

  static const Set<String> gemmaChatTemplateModels = <String>{
    gemma2_2bIt,
  };
}
