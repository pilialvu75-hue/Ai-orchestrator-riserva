import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime-owned budgeting can bypass legacy character bound', () {
    final veryLargeTurn = 'legacy-marker ' + ('x' * 12000);
    final context = <ChatTurn>[
      ChatTurn(role: ChatRole.user, content: veryLargeTurn),
      const ChatTurn(role: ChatRole.assistant, content: 'answer-marker'),
    ];

    final legacyPrompt = LocalPromptTemplates.compose(
      modelId: 'phi3_5_mini',
      systemPrompt: 'system',
      prompt: 'current question',
      context: context,
    );
    final runtimeBudgetPrompt = LocalPromptTemplates.compose(
      modelId: 'phi3_5_mini',
      systemPrompt: 'system',
      prompt: 'current question',
      context: context,
      enforceLegacyContextBound: false,
    );

    expect(legacyPrompt, isNot(contains('legacy-marker')));
    expect(runtimeBudgetPrompt, contains('legacy-marker'));
    expect(runtimeBudgetPrompt, contains('answer-marker'));
  });
}
