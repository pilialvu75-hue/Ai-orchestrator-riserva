import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalPromptTemplates', () {
    test('Qwen 2.5 uses ChatML instead of a plain transcript', () {
      for (final id in ['qwen2_5_3b_instruct', 'Qwen2.5-3B-Instruct']) {
        final prompt = LocalPromptTemplates.compose(
          modelId: id,
          prompt: 'ciao',
          systemPrompt: 'Rispondi in italiano.',
          context: const [
            ChatTurn(role: ChatRole.user, content: 'Mi chiamo Roberto.'),
            ChatTurn(role: ChatRole.assistant, content: 'Piacere Roberto.'),
          ],
        );
        expect(prompt, contains('<|im_start|>system\nRispondi in italiano.'));
        expect(prompt, contains('<|im_start|>user\nMi chiamo Roberto.\n<|im_end|>'));
        expect(prompt, contains('<|im_start|>assistant\nPiacere Roberto.\n<|im_end|>'));
        expect(prompt, endsWith('<|im_start|>user\nciao\n<|im_end|>\n<|im_start|>assistant\n'));
        expect(prompt, isNot(contains('/no_think')));
        expect(prompt, isNot(contains('User:')));
      }
    });

    test('Qwen3 keeps its thinking control within ChatML', () {
      final prompt = LocalPromptTemplates.compose(
        modelId: LocalInferenceModelIds.qwen3_1_7b,
        prompt: 'ciao',
      );
      expect(prompt, contains('<|im_start|>user\n/no_think\nciao\n<|im_end|>'));
      expect(prompt, endsWith('<|im_start|>assistant\n'));
    });

    test('uses the Phi-3 template for Phi-3.5 Mini', () {
      RuntimeEventLog.instance.clear();
      expect(
        LocalInferenceModelIds.resolveTemplate('phi3_5_mini'),
        'phi3',
      );
      expect(
        LocalInferenceModelIds.resolveTemplate('Phi-3.5-Mini-Instruct'),
        'phi3',
      );

      final prompt = LocalPromptTemplates.compose(
        modelId: 'phi3_5_mini',
        prompt: 'Hello',
        systemPrompt: 'Be concise.',
        context: const [
          ChatTurn(role: ChatRole.user, content: 'Earlier question'),
        ],
      );

      expect(prompt, contains('<|system|>'));
      expect(prompt, contains('<|user|>'));
      expect(prompt, contains('<|assistant|>'));
      expect(prompt, contains('<|end|>'));
      expect(prompt, isNot(contains('<!--META')));
      expect(prompt, isNot(contains('<|im_start|>')));
      expect(prompt, isNot(contains('Respond in max 3 sentences')));
      expect(
        RuntimeEventLog.instance.entries.any(
          (entry) => entry.message.contains('[PROMPT_BEGIN]'),
        ),
        isTrue,
      );
      expect(
        RuntimeEventLog.instance.entries.any(
          (entry) => entry.message.contains('[PROMPT_SENT]'),
        ),
        isTrue,
      );
    });
  });
}
