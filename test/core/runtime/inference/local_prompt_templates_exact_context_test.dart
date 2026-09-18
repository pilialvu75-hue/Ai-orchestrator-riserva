import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalPromptTemplates exact context path', () {
    final context = List<ChatTurn>.generate(
      82,
      (index) => ChatTurn(
        role: index.isEven ? ChatRole.user : ChatRole.assistant,
        content: 'turn-$index',
      ),
      growable: false,
    );

    test('keeps legacy bound enabled by default', () {
      final prompt = LocalPromptTemplates.compose(
        modelId: LocalInferenceModelIds.phi35Mini,
        prompt: 'current',
        context: context,
      );

      expect(prompt, isNot(contains('turn-0')));
      expect(prompt, contains('turn-81'));
    });

    test('exact-token caller can bypass legacy character and turn bound', () {
      final prompt = LocalPromptTemplates.compose(
        modelId: LocalInferenceModelIds.phi35Mini,
        prompt: 'current',
        context: context,
        applyLegacyContextBound: false,
      );

      expect(prompt, contains('turn-0'));
      expect(prompt, contains('turn-81'));
    });
  });
}
