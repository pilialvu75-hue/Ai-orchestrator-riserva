import 'package:ai_orchestrator/core/runtime/inference/runtime_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RuntimeStateMachine', () {
    test('starts uninitialized and not ready', () {
      final stateMachine = RuntimeStateMachine();

      expect(stateMachine.state, RuntimeLifecycleState.uninitialized);
      expect(stateMachine.isEverReady, isFalse);
      expect(stateMachine.isReady, isFalse);
      expect(stateMachine.hasLoadedModel, isFalse);
    });

    test('self-test success forces ready latch', () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.applyEvent(RuntimeEvent.modelDetected, source: 'test');
      stateMachine.applyEvent(RuntimeEvent.selfTestSucceeded, source: 'test');

      expect(stateMachine.state, RuntimeLifecycleState.ready);
      expect(stateMachine.isEverReady, isTrue);
      expect(stateMachine.isCurrentlyHealthy, isTrue);
      expect(stateMachine.isReady, isTrue);
    });

    test('runtimeUnavailable cannot overwrite ready after self-test success', () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.applyEvent(RuntimeEvent.modelDetected, source: 'test');
      stateMachine.applyEvent(RuntimeEvent.selfTestSucceeded, source: 'test');
      stateMachine.applyEvent(
        RuntimeEvent.runtimeUnavailableObserved,
        source: 'diagnostics',
      );

      expect(stateMachine.state, RuntimeLifecycleState.ready);
      expect(stateMachine.isReady, isTrue);
    });

    test('inference can start from loading and return to loading on completion',
        () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.applyEvent(RuntimeEvent.modelDetected, source: 'test');
      stateMachine.applyEvent(RuntimeEvent.loadRequested, source: 'test');
      stateMachine.applyEvent(RuntimeEvent.inferenceStarted, source: 'test');
      expect(stateMachine.state, RuntimeLifecycleState.inferencing);

      stateMachine.applyEvent(RuntimeEvent.inferenceCompleted, source: 'test');
      expect(stateMachine.state, RuntimeLifecycleState.loading);
    });

    test('pre-ready error transitions to failed', () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.applyEvent(RuntimeEvent.modelDetected, source: 'test');
      stateMachine.applyEvent(RuntimeEvent.errorObserved, source: 'test');

      expect(stateMachine.state, RuntimeLifecycleState.failed);
      expect(stateMachine.isEverReady, isFalse);
      expect(stateMachine.isReady, isFalse);
    });

    test('ready state is irreversible until resetHard', () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.applyEvent(RuntimeEvent.modelDetected, source: 'test');
      stateMachine.applyEvent(RuntimeEvent.selfTestSucceeded, source: 'test');
      stateMachine.applyEvent(RuntimeEvent.loadRequested, source: 'test');
      stateMachine.applyEvent(RuntimeEvent.errorObserved, source: 'test');
      stateMachine.applyEvent(
        RuntimeEvent.runtimeUnavailableObserved,
        source: 'diagnostics',
      );

      expect(stateMachine.isEverReady, isTrue);
      expect(stateMachine.isReady, isTrue);
      expect(stateMachine.state, RuntimeLifecycleState.ready);

      stateMachine.resetHard();
      expect(stateMachine.state, RuntimeLifecycleState.uninitialized);
      expect(stateMachine.isEverReady, isFalse);
      expect(stateMachine.isReady, isFalse);
    });

    test('resetSoft does not clear readiness latch', () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.applyEvent(RuntimeEvent.modelDetected, source: 'test');
      stateMachine.applyEvent(RuntimeEvent.selfTestSucceeded, source: 'test');

      stateMachine.resetSoft();

      expect(stateMachine.state, RuntimeLifecycleState.ready);
      expect(stateMachine.isEverReady, isTrue);
      expect(stateMachine.isReady, isTrue);
    });

    test('model detection only updates metadata and never readiness directly', () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.applyEvent(RuntimeEvent.modelDetected, source: 'test');
      expect(stateMachine.hasLoadedModel, isTrue);
      expect(stateMachine.isEverReady, isFalse);
      expect(stateMachine.isReady, isFalse);

      stateMachine.applyEvent(RuntimeEvent.modelCleared, source: 'test');
      expect(stateMachine.hasLoadedModel, isFalse);
      expect(stateMachine.isEverReady, isFalse);
      expect(stateMachine.isReady, isFalse);
    });
  });
}
