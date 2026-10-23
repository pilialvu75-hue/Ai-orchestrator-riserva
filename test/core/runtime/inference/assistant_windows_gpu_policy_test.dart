import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/runtime/inference/assistant_windows_gpu_policy.dart';

void main() {
  test('measured downloaded catalog profiles and filenames are eligible', () {
    const pairs = {
      'deepseek_r1_1_5b': 'DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf',
      'gemma_2b_it': 'gemma-2-2b-it-Q4_K_M.gguf',
      'llama3_2_1b': 'llama-3.2-1b-instruct-q4_k_m.gguf',
      'llama3_2_3b': 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
      'nemotron3_nano_4b': 'NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf',
      'phi3_5_mini': 'Phi-3.5-mini-instruct-Q4_K_M.gguf',
      'qwen3_1_7b': 'Qwen3-1.7B-Q4_K_M.gguf',
      'qwen3_4b': 'Qwen3-4B-Q4_K_M.gguf',
      'spark_x2_5_4b': 'Spark-X2.5-4B-Q4_K_M.gguf',
    };
    for (final pair in pairs.entries) {
      expect(AssistantWindowsGpuPolicy.supports(pair.key), isTrue, reason: pair.key);
      expect(AssistantWindowsGpuPolicy.supports(pair.value), isTrue, reason: pair.value);
    }
  });
  test('family membership alone cannot enable unmeasured models or legacy TinyLlama', () {
    for (final id in ['', 'llama_1b', 'tinyllama', 'gemma_2b',
      'deepseek_r1_7b', 'qwen3_8b', 'llama3_2_70b', 'mistral',
      'custom-qwen3-4b.gguf', 'custom-model.gguf']) {
      expect(AssistantWindowsGpuPolicy.supports(id), isFalse, reason: id);
    }
  });
  test('catalog matching is case-insensitive and trims whitespace', () {
    expect(AssistantWindowsGpuPolicy.supports(' QWEN3_4B '), isTrue);
  });
}
