import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalPromptTemplates', () {
    test('uses the Phi-3 template for Phi-3.5 Mini', () {
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
      expect(prompt, isNot(contains('<|im_start|>')));
    });
  });
}
