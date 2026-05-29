import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/core/runtime/inference/prompt_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalPromptTemplates', () {
    test('renders llama history as structured turns instead of flattened text', () {
      final prompt = LocalPromptTemplates.compose(
        modelId: LocalInferenceModelIds.llama1b,
        prompt: 'Switch topics: explain maps.',
        systemPrompt: 'You are helpful.',
        context: const <String>[
          'user: old question',
          'assistant: old answer',
        ],
        contextTurns: const <PromptTurn>[
          PromptTurn(role: 'user', content: 'Tell me about trees.'),
          PromptTurn(role: 'assistant', content: 'Trees are hierarchical.'),
        ],
        recalledContext: const <String>['assistant: Earlier we discussed graphs.'],
      );

      expect(
        prompt,
        contains('<|start_header_id|>user<|end_header_id|>\n\nTell me about trees.<|eot_id|>'),
      );
      expect(
        prompt,
        contains(
          '<|start_header_id|>assistant<|end_header_id|>\n\nTrees are hierarchical.<|eot_id|>',
        ),
      );
      expect(
        prompt,
        isNot(contains('user: old question\nassistant: old answer\nSwitch topics: explain maps.')),
      );
      expect(
        prompt,
        contains('Relevant past context (use only if it helps answer the latest user request'),
      );
    });

    test('renders qwen history as alternating chatml turns', () {
      final prompt = LocalPromptTemplates.compose(
        modelId: LocalInferenceModelIds.qwen3_1_7b,
        prompt: 'Now summarize arrays.',
        contextTurns: const <PromptTurn>[
          PromptTurn(role: 'user', content: 'What is a linked list?'),
          PromptTurn(role: 'assistant', content: 'A linked list stores nodes.'),
        ],
      );

      expect(prompt, contains('<|im_start|>user\nWhat is a linked list?\n<|im_end|>'));
      expect(
        prompt,
        contains('<|im_start|>assistant\nA linked list stores nodes.\n<|im_end|>'),
      );
      expect(prompt, contains('<|im_start|>user\n/no_think\nNow summarize arrays.\n<|im_end|>'));
    });
  });
}
