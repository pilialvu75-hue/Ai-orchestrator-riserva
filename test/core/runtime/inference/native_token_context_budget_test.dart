import 'package:ai_orchestrator/core/runtime/inference/native_token_context_budget.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String render(List<ChatTurn> context) {
    return <String>[
      'system',
      'current',
      ...context.map((turn) => turn.content),
    ].join(' ');
  }

  int countWords(String prompt) => prompt
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .length;

  group('NativeTokenContextBudget', () {
    test('keeps the full coherent history when it fits', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'u1'),
        ChatTurn(role: ChatRole.assistant, content: 'a1'),
      ];

      final result = NativeTokenContextBudget.select(
        context: context,
        renderPrompt: render,
        countTokens: countWords,
        nCtx: 16,
        requestedGenerationTokens: 6,
        safetyMargin: 1,
      );

      expect(result.context, context);
      expect(result.trimmedTurns, 0);
      expect(result.promptTokens, 4);
      expect(result.fitsRequestedGeneration, isTrue);
    });

    test('drops the oldest complete exchange and never starts with assistant', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'old user'),
        ChatTurn(role: ChatRole.assistant, content: 'old answer'),
        ChatTurn(role: ChatRole.user, content: 'new user'),
        ChatTurn(role: ChatRole.assistant, content: 'new answer'),
      ];

      final result = NativeTokenContextBudget.select(
        context: context,
        renderPrompt: render,
        countTokens: countWords,
        nCtx: 12,
        requestedGenerationTokens: 4,
        safetyMargin: 1,
      );

      expect(result.trimmedTurns, 2);
      expect(result.context, const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'new user'),
        ChatTurn(role: ChatRole.assistant, content: 'new answer'),
      ]);
      expect(result.context.first.role, ChatRole.user);
      expect(result.promptTokens, 6);
      expect(result.fitsRequestedGeneration, isTrue);
    });

    test('removes a leading orphan assistant even when capacity is ample', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.assistant, content: 'orphan'),
        ChatTurn(role: ChatRole.user, content: 'question'),
        ChatTurn(role: ChatRole.assistant, content: 'answer'),
      ];

      final result = NativeTokenContextBudget.select(
        context: context,
        renderPrompt: render,
        countTokens: countWords,
        nCtx: 32,
        requestedGenerationTokens: 8,
        safetyMargin: 1,
      );

      expect(result.trimmedTurns, 1);
      expect(result.context.first.role, ChatRole.user);
      expect(result.context.map((turn) => turn.content), <String>[
        'question',
        'answer',
      ]);
    });

    test('keeps current prompt intact when requested headroom cannot fit', () {
      final result = NativeTokenContextBudget.select(
        context: const <ChatTurn>[
          ChatTurn(role: ChatRole.user, content: 'old'),
          ChatTurn(role: ChatRole.assistant, content: 'answer'),
        ],
        renderPrompt: (_) => 'one two three four five six seven',
        countTokens: countWords,
        nCtx: 10,
        requestedGenerationTokens: 4,
        safetyMargin: 1,
      );

      expect(result.context, isEmpty);
      expect(result.promptTokens, 7);
      expect(result.promptBudgetTokens, 5);
      expect(result.availableGenerationTokens, 2);
      expect(result.fitsRequestedGeneration, isFalse);
    });

    test('rejects invalid capacity arguments', () {
      expect(
        () => NativeTokenContextBudget.select(
          context: const <ChatTurn>[],
          renderPrompt: render,
          countTokens: countWords,
          nCtx: 0,
          requestedGenerationTokens: 1,
          safetyMargin: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}
