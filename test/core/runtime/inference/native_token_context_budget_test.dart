import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/native_token_context_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String compose(List<ChatTurn> context) {
    final history = context
        .map((turn) => '${turn.role.name}:${turn.content}')
        .join('|');
    return 'SYSTEM|$history|USER:current question|ASSISTANT:';
  }

  int countCharsAsTokens(String prompt) => prompt.length;

  group('NativeTokenContextBudget', () {
    test('keeps the largest recent suffix that fits on a user boundary', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'u1-old'),
        ChatTurn(role: ChatRole.assistant, content: 'a1-old'),
        ChatTurn(role: ChatRole.user, content: 'u2-keep'),
        ChatTurn(role: ChatRole.assistant, content: 'a2-keep'),
        ChatTurn(role: ChatRole.user, content: 'u3-latest'),
        ChatTurn(role: ChatRole.assistant, content: 'a3-latest'),
      ];

      final expected = context.sublist(2);
      final budget = countCharsAsTokens(compose(expected));

      final result = NativeTokenContextBudget.select(
        context: context,
        composePrompt: compose,
        countTokens: countCharsAsTokens,
        maxPromptTokens: budget,
      );

      expect(result.context, expected);
      expect(result.context.first.role, ChatRole.user);
      expect(result.droppedTurns, 2);
      expect(result.wasTrimmed, isTrue);
      expect(result.promptTokens, lessThanOrEqualTo(budget));
      expect(result.prompt, contains('USER:current question'));
    });

    test('never starts visible history with an assistant turn', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.assistant, content: 'orphan'),
        ChatTurn(role: ChatRole.user, content: 'question'),
        ChatTurn(role: ChatRole.assistant, content: 'answer'),
      ];

      final result = NativeTokenContextBudget.select(
        context: context,
        composePrompt: compose,
        countTokens: countCharsAsTokens,
        maxPromptTokens: 10000,
      );

      expect(result.context, hasLength(2));
      expect(result.context.first.role, ChatRole.user);
      expect(result.context.first.content, 'question');
    });

    test('filters system, excluded and empty turns before budgeting', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.system, content: 'duplicate system'),
        ChatTurn(
          role: ChatRole.user,
          content: 'excluded',
          excludeFromContext: true,
        ),
        ChatTurn(role: ChatRole.user, content: '   '),
        ChatTurn(role: ChatRole.user, content: ' kept '),
        ChatTurn(role: ChatRole.assistant, content: ' answer '),
      ];

      final result = NativeTokenContextBudget.select(
        context: context,
        composePrompt: compose,
        countTokens: countCharsAsTokens,
        maxPromptTokens: 10000,
      );

      expect(result.context, hasLength(2));
      expect(result.context[0].content, 'kept');
      expect(result.context[1].content, 'answer');
    });

    test('preserves current prompt even when no history can fit', () {
      const context = <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'old question'),
        ChatTurn(role: ChatRole.assistant, content: 'old answer'),
      ];

      final emptyPrompt = compose(const <ChatTurn>[]);
      final result = NativeTokenContextBudget.select(
        context: context,
        composePrompt: compose,
        countTokens: countCharsAsTokens,
        maxPromptTokens: emptyPrompt.length - 1,
      );

      expect(result.context, isEmpty);
      expect(result.prompt, emptyPrompt);
      expect(result.promptTokens, greaterThan(result.maxPromptTokens));
      expect(result.droppedTurns, 2);
    });

    test('uses logarithmic prompt probes for long history', () {
      final context = <ChatTurn>[];
      for (var index = 0; index < 40; index++) {
        context.add(ChatTurn(role: ChatRole.user, content: 'u$index'));
        context.add(ChatTurn(role: ChatRole.assistant, content: 'a$index'));
      }

      var probes = 0;
      int counted(String prompt) {
        probes++;
        return prompt.length;
      }

      final half = context.sublist(40);
      final result = NativeTokenContextBudget.select(
        context: context,
        composePrompt: compose,
        countTokens: counted,
        maxPromptTokens: compose(half).length,
      );

      expect(result.context.length, 40);
      expect(result.context.first.role, ChatRole.user);
      // 41 possible user/empty boundaries require at most 6 binary-search
      // probes plus one cached/final evaluation.
      expect(probes, lessThanOrEqualTo(7));
    });
  });
}
