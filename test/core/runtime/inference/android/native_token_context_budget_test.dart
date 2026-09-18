import 'package:ai_orchestrator/core/runtime/inference/android/native_token_context_budget.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String compose(List<ChatTurn> context) {
    final body = context.map((turn) => turn.content).join(' ');
    return 'system $body current-user'.trim();
  }

  int countWords(String prompt) =>
      prompt.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).length;

  group('NativeTokenContextBudget', () {
    test('keeps the entire normalized history when the exact prompt fits', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'first'),
        ChatTurn(role: ChatRole.assistant, content: 'answer'),
        ChatTurn(role: ChatRole.user, content: 'second'),
        ChatTurn(role: ChatRole.assistant, content: 'reply'),
      ];

      final result = NativeTokenContextBudget.fit(
        contextTurns: context,
        maxPromptTokens: 20,
        composePrompt: compose,
        countTokens: countWords,
      );

      expect(result.contextTurns, context);
      expect(result.trimmedTurns, 0);
      expect(result.fitsRequestedBudget, isTrue);
    });

    test('trims to the earliest recent user boundary that fits', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'old question words'),
        ChatTurn(role: ChatRole.assistant, content: 'old answer words'),
        ChatTurn(role: ChatRole.user, content: 'new question'),
        ChatTurn(role: ChatRole.assistant, content: 'new answer'),
      ];

      final result = NativeTokenContextBudget.fit(
        contextTurns: context,
        // system(1) + new pair(4) + current-user(1) = 6
        maxPromptTokens: 6,
        composePrompt: compose,
        countTokens: countWords,
      );

      expect(result.contextTurns, const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'new question'),
        ChatTurn(role: ChatRole.assistant, content: 'new answer'),
      ]);
      expect(result.trimmedTurns, 2);
      expect(result.fitsRequestedBudget, isTrue);
    });

    test('never leaves an assistant response as the first visible turn', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.assistant, content: 'orphan'),
        ChatTurn(role: ChatRole.user, content: 'valid question'),
        ChatTurn(role: ChatRole.assistant, content: 'valid answer'),
      ];

      final result = NativeTokenContextBudget.fit(
        contextTurns: context,
        maxPromptTokens: 20,
        composePrompt: compose,
        countTokens: countWords,
      );

      expect(result.contextTurns.first.role, ChatRole.user);
      expect(
        result.contextTurns.map((turn) => turn.content),
        isNot(contains('orphan')),
      );
    });

    test('returns empty history when base prompt alone exceeds headroom', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'history'),
        ChatTurn(role: ChatRole.assistant, content: 'answer'),
      ];

      final result = NativeTokenContextBudget.fit(
        contextTurns: context,
        maxPromptTokens: 1,
        composePrompt: compose,
        countTokens: countWords,
      );

      expect(result.contextTurns, isEmpty);
      expect(result.fitsRequestedBudget, isFalse);
      expect(result.trimmedTurns, context.length);
    });

    test('ignores excluded, system and blank turns before budgeting', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.system, content: 'old system'),
        ChatTurn(
          role: ChatRole.user,
          content: 'excluded',
          excludeFromContext: true,
        ),
        ChatTurn(role: ChatRole.user, content: '  kept  '),
        ChatTurn(role: ChatRole.assistant, content: 'answer'),
      ];

      final result = NativeTokenContextBudget.fit(
        contextTurns: context,
        maxPromptTokens: 20,
        composePrompt: compose,
        countTokens: countWords,
      );

      expect(result.contextTurns, const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'kept'),
        ChatTurn(role: ChatRole.assistant, content: 'answer'),
      ]);
    });
  });
}
