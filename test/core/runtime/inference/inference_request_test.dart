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

    test('preserves execution while replacing only the attempt identity', () {
      const request = InferenceRequest(
        sessionId: 'session-1',
        prompt: 'hello',
        requestId: 'request-1',
        projectId: 'project-1',
        taskId: 'task-1',
        executionId: 'execution-1',
        attemptId: 'attempt-1',
        checkpointId: 'checkpoint-1',
      );

      final next = request.copyWith(
        attemptId: 'attempt-2',
        checkpointId: 'checkpoint-2',
      );

      expect(next.sessionId, 'session-1');
      expect(next.requestId, 'request-1');
      expect(next.projectId, 'project-1');
      expect(next.taskId, 'task-1');
      expect(next.executionId, 'execution-1');
      expect(next.attemptId, 'attempt-2');
      expect(next.checkpointId, 'checkpoint-2');
    });
  });

  group('InferenceRequest model defaults', () {
    test('recognises Phi 3.5 model family', () {
      expect(InferenceRequest.maxTokensForModel('phi3_5_mini'), 1024);
      expect(InferenceRequest.temperatureForModel('phi3_5_mini'), 0.5);
    });
  });
}
