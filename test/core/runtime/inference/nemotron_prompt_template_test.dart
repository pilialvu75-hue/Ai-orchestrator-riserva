import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Nano 4B uses NVIDIA text-only non-thinking generation format', () {
    for (final id in [
      'nemotron3_nano_4b',
      'NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf',
      'nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16',
    ]) {
      expect(LocalInferenceModelIds.resolveTemplate(id),
          LocalInferenceModelIds.templateNemotron);
      final result = LocalPromptTemplates.compose(
        modelId: id,
        systemPrompt: 'Rispondi in italiano.',
        prompt: 'Di che colore è la mela?',
        emitDiagnostics: false,
      );
      expect(result,
          '<|im_start|>system\nRispondi in italiano.<|im_end|>\n'
          '<|im_start|>user\nDi che colore è la mela?<|im_end|>\n'
          '<|im_start|>assistant\n<think></think>');
      expect(result, isNot(contains('/no_think')));
    }
  });

  test('history preserves answers and user text without historical reasoning', () {
    final result = LocalPromptTemplates.compose(
      modelId: LocalInferenceModelIds.nemotron3Nano4b,
      systemPrompt: 'S',
      prompt: 'Continua.',
      context: const [
        ChatTurn(role: ChatRole.user, content: 'Cita Assistant: e <think>.'),
        ChatTurn(role: ChatRole.assistant,
            content: '<think>old internal reasoning</think>Risposta.'),
      ],
      emitDiagnostics: false,
    );
    expect(result,
        '<|im_start|>system\nS<|im_end|>\n'
        '<|im_start|>user\nCita Assistant: e <think>.<|im_end|>\n'
        '<|im_start|>assistant\n<think></think>Risposta.<|im_end|>\n'
        '<|im_start|>user\nContinua.<|im_end|>\n'
        '<|im_start|>assistant\n<think></think>');
  });

  test('Nemotron template does not capture other model families', () {
    expect(LocalInferenceModelIds.resolveTemplate('phi3_5_mini'), 'phi3');
    expect(LocalInferenceModelIds.resolveTemplate('qwen3_1_7b'), 'qwen3');
    expect(LocalInferenceModelIds.resolveTemplate('nemotron-3-nano-30b'),
        isNot(LocalInferenceModelIds.templateNemotron));
  });

  test('Nemotron retains the Local web-search protocol', () {
    final result = LocalPromptTemplates.compose(
      modelId: LocalInferenceModelIds.nemotron3Nano4b,
      prompt: 'Cerca online il meteo.',
      emitDiagnostics: false,
    );
    expect(result, contains('<search>query</search>'));
    expect(result, endsWith('<|im_start|>assistant\n<think></think>'));
  });
}
