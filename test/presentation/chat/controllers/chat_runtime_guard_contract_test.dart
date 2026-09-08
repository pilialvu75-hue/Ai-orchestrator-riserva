import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_event.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/chat_deadlock_controller.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/runtime_state_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('assistant UI runtime guard contract', () {
    test('legacy 15-second timeout is clamped behind runtime watchdogs', () {
      final controller = ChatDeadlockController(
        timeout: const Duration(seconds: 15),
      );

      expect(
        controller.timeout,
        ChatDeadlockController.minimumSafeTimeout,
      );
      expect(
        controller.timeout,
        const Duration(minutes: 3),
      );

      controller.dispose();
    });

    test('longer explicit timeout is preserved', () {
      final controller = ChatDeadlockController(
        timeout: const Duration(minutes: 4),
      );

      expect(controller.timeout, const Duration(minutes: 4));

      controller.dispose();
    });

    test('loading and tokenizing count as active runtime work', () {
      expect(
        RuntimeStateController.isRuntimeActiveStatus(
          LocalRuntimeStatus.loading,
        ),
        isTrue,
      );
      expect(
        RuntimeStateController.isRuntimeActiveStatus(
          LocalRuntimeStatus.tokenizing,
        ),
        isTrue,
      );
      expect(
        RuntimeStateController.isRuntimeActiveStatus(
          LocalRuntimeStatus.inferencing,
        ),
        isTrue,
      );
      expect(
        RuntimeStateController.isRuntimeActiveStatus(
          LocalRuntimeStatus.streaming,
        ),
        isTrue,
      );
    });

    test('idle and terminal runtime states do not masquerade as active work', () {
      expect(
        RuntimeStateController.isRuntimeActiveStatus(
          LocalRuntimeStatus.ready,
        ),
        isFalse,
      );
      expect(
        RuntimeStateController.isRuntimeActiveStatus(
          LocalRuntimeStatus.completed,
        ),
        isFalse,
      );
      expect(
        RuntimeStateController.isRuntimeActiveStatus(
          LocalRuntimeStatus.timedOut,
        ),
        isFalse,
      );
      expect(
        RuntimeStateController.isRuntimeActiveStatus(
          LocalRuntimeStatus.stalled,
        ),
        isFalse,
      );
      expect(
        RuntimeStateController.isRuntimeActiveStatus(
          LocalRuntimeStatus.failed,
        ),
        isFalse,
      );
    });

    test('UI recovery message never claims unconfirmed cancellation', () {
      const event = RecoverFromStuckUiEvent(
        sessionId: 'default',
        runtimeMessage:
            'Local runtime stalled before first token. Request cancelled and UI recovered.',
      );

      expect(
        event.runtimeMessage,
        'Local runtime wait guard expired before first token. UI recovered; request cancellation was not confirmed.',
      );
      expect(event.runtimeMessage, isNot(contains('Request cancelled')));
    });

    test('custom recovery messages are preserved', () {
      const event = RecoverFromStuckUiEvent(
        sessionId: 'default',
        runtimeMessage: 'Custom recovery notice.',
      );

      expect(event.runtimeMessage, 'Custom recovery notice.');
    });
  });
}
