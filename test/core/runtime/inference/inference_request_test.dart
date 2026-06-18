import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InferenceRequest copyWith', () {
    test('clones the original context list', () {
      final sourceContext = <ChatTurn>[
        const ChatTurn(role: ChatRole.user, content: 'alpha'),
      ];
      final request = InferenceRequest(
        sessionId: 'session-1',
        prompt: 'hello',
        context: sourceContext,
      );

      final copy = request.copyWith();

      sourceContext.add(
        const ChatTurn(role: ChatRole.assistant, content: 'beta'),
      );

      expect(request.context, <ChatTurn>[
        const ChatTurn(role: ChatRole.user, content: 'alpha'),
        const ChatTurn(role: ChatRole.assistant, content: 'beta'),
      ]);
      expect(copy.context, <ChatTurn>[
        const ChatTurn(role: ChatRole.user, content: 'alpha'),
      ]);
    });

    test('clones the replacement context list', () {
      final replacementContext = <ChatTurn>[
        const ChatTurn(role: ChatRole.user, content: 'one'),
      ];
      const request = InferenceRequest(
        sessionId: 'session-1',
        prompt: 'hello',
      );

      final copy = request.copyWith(context: replacementContext);

      replacementContext.add(
        const ChatTurn(role: ChatRole.assistant, content: 'two'),
      );

      expect(copy.context, <ChatTurn>[
        const ChatTurn(role: ChatRole.user, content: 'one'),
      ]);
      expect(
        () => copy.context.add(
          const ChatTurn(role: ChatRole.user, content: 'three'),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('InferenceRequest model defaults', () {
    test('recognises Phi 3.5 model family', () {
      expect(InferenceRequest.maxTokensForModel('phi3_5_mini'), 768);
      expect(InferenceRequest.temperatureForModel('phi3_5_mini'), 0.5);
    });
  });
}
