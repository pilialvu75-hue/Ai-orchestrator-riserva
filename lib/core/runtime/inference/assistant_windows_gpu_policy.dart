import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';

/// Windows Assistant profiles exercised with the bundled Vulkan engine.
/// This is an explicit compatibility list, not a general family/GGUF allow rule.
/// Device selection and VRAM headroom checks remain mandatory in the provider.
abstract final class AssistantWindowsGpuPolicy {
  static const _measuredModels = <String>{
    'deepseek_r1_1_5b',
    'gemma_2b_it',
    'llama3_2_1b',
    'llama3_2_3b',
    'phi3_5_mini',
    'qwen3_1_7b',
    'qwen3_4b',
    'spark_x2_5_4b',
    'deepseek-r1-distill-qwen-1.5b-q4_k_m.gguf',
    'gemma-2-2b-it-q4_k_m.gguf',
    'llama-3.2-1b-instruct-q4_k_m.gguf',
    'llama-3.2-3b-instruct-q4_k_m.gguf',
    'phi-3.5-mini-instruct-q4_k_m.gguf',
    'qwen3-1.7b-q4_k_m.gguf',
    'qwen3-4b-q4_k_m.gguf',
    'spark-x2.5-4b-q4_k_m.gguf',
  };

  static bool supports(String modelId) {
    // Preserve the previously supported Nemotron route.
    if (LocalInferenceModelIds.resolveTemplate(modelId) ==
        LocalInferenceModelIds.templateNemotron) return true;
    return _measuredModels.contains(modelId.trim().toLowerCase());
  }
}
