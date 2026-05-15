import 'package:ai_orchestrator/core/runtime/inference/runtime_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RuntimeStateMachine', () {
    test('starts uninitialized', () {
      final stateMachine = RuntimeStateMachine();

      expect(stateMachine.state, RuntimeLifecycleState.uninitialized);
    });

    test('follows deterministic runtime transitions', () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.markLoading();
      expect(stateMachine.state, RuntimeLifecycleState.loading);

      stateMachine.markReady();
      expect(stateMachine.state, RuntimeLifecycleState.ready);

      stateMachine.markInferencing();
      expect(stateMachine.state, RuntimeLifecycleState.inferencing);

      stateMachine.markInferenceCompleted();
      expect(stateMachine.state, RuntimeLifecycleState.ready);
    });

    test('enters failed on runtime failure and can recover on reload', () {
      final stateMachine = RuntimeStateMachine()
        ..markLoading()
        ..markInferencing()
        ..markFailed();

      expect(stateMachine.state, RuntimeLifecycleState.failed);

      stateMachine.markLoading();
      stateMachine.markReady();

      expect(stateMachine.state, RuntimeLifecycleState.ready);
    });

    test('reset returns to uninitialized', () {
      final stateMachine = RuntimeStateMachine()
        ..markLoading()
        ..markInferencing();

      stateMachine.reset();

      expect(stateMachine.state, RuntimeLifecycleState.uninitialized);
    });
  });
}
