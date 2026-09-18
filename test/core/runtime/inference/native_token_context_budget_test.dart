import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/native_token_context_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String render(List<ChatTurn> context) {
    return <String>[
      'system',
      ...context.map((turn) => turn.content),
      'current',
    ].join(' ');
  }

  int countWords(String prompt) => prompt
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .length;

  group('NativeTokenContextBudget', () {
    test('keeps full coherent history when it fits', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'u1'),
        ChatTurn(role: ChatRole.assistant, content: 'a1'),
      ];

      final result = NativeTokenContextBudget.select(
        context: context,
        composePrompt: render,
        countTokens: countWords,
        nCtx: 16,
        requestedGenerationTokens: 6,
        safetyMargin: 1,
      );

      expect(result.context, context);
      expect(result.droppedTurns, 0);
      expect(result.promptTokens, 4);
      expect(result.fitsRequestedGeneration, isTrue);
    });

    test('drops oldest exchange and never starts with assistant', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'old user'),
        ChatTurn(role: ChatRole.assistant, content: 'old answer'),
        ChatTurn(role: ChatRole.user, content: 'new user'),
        ChatTurn(role: ChatRole.assistant, content: 'new answer'),
      ];

      final result = NativeTokenContextBudget.select(
        context: context,
        composePrompt: render,
        countTokens: countWords,
        nCtx: 12,
        requestedGenerationTokens: 4,
        safetyMargin: 1,
      );

      expect(result.droppedTurns, 2);
      expect(result.context, const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'new user'),
        ChatTurn(role: ChatRole.assistant, content: 'new answer'),
      ]);
      expect(result.context.first.role, ChatRole.user);
      expect(result.promptTokens, 6);
    });

    test('filters excluded, system and orphan assistant turns', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.system, content: 'legacy system'),
        ChatTurn(role: ChatRole.assistant, content: 'orphan'),
        ChatTurn(
          role: ChatRole.user,
          content: 'hidden',
          excludeFromContext: true,
        ),
        ChatTurn(role: ChatRole.user, content: ' question '),
        ChatTurn(role: ChatRole.assistant, content: ' answer '),
      ];

      final result = NativeTokenContextBudget.select(
        context: context,
        composePrompt: render,
        countTokens: countWords,
        nCtx: 32,
        requestedGenerationTokens: 8,
        safetyMargin: 1,
      );

      expect(result.context, const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'question'),
        ChatTurn(role: ChatRole.assistant, content: 'answer'),
      ]);
      expect(result.context.first.role, ChatRole.user);
    });

    test('keeps current prompt intact when requested headroom cannot fit', () {
      final result = NativeTokenContextBudget.select(
        context: const <ChatTurn>[
          ChatTurn(role: ChatRole.user, content: 'old'),
          ChatTurn(role: ChatRole.assistant, content: 'answer'),
        ],
        composePrompt: (_) => 'one two three four five six seven',
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

    test('uses logarithmic probes over long histories', () {
      final context = <ChatTurn>[];
      for (var i = 0; i < 64; i++) {
        context
          ..add(ChatTurn(role: ChatRole.user, content: 'u$i'))
          ..add(ChatTurn(role: ChatRole.assistant, content: 'a$i'));
      }

      var probes = 0;
      NativeTokenContextBudget.select(
        context: context,
        composePrompt: render,
        countTokens: (prompt) {
          probes++;
          return countWords(prompt);
        },
        nCtx: 90,
        requestedGenerationTokens: 20,
        safetyMargin: 2,
      );

      // 65 coherent candidates require at most 7 binary-search probes plus
      // small constant overhead. This protects first-token latency.
      expect(probes, lessThanOrEqualTo(8));
    });

    test('rejects invalid capacity arguments', () {
      expect(
        () => NativeTokenContextBudget.select(
          context: const <ChatTurn>[],
          composePrompt: render,
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
