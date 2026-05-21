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

    test('ignores invalid transition from uninitialized to inferencing', () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.markInferencing();

      expect(stateMachine.state, RuntimeLifecycleState.uninitialized);
    });

    // Regression: after a verified warmup skip the state machine may be in
    // `loading` when the production stream starts.  It must be possible to
    // transition directly loading → inferencing so the machine is never
    // permanently stuck in `loading` during an active generation stream.
    test('allows loading → inferencing transition for verified inference path',
        () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.markLoading();
      expect(stateMachine.state, RuntimeLifecycleState.loading);

      stateMachine.markInferencing();
      expect(stateMachine.state, RuntimeLifecycleState.inferencing);
    });

    test(
        'inference completes back to pre-inference state when started from loading',
        () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.markLoading();
      stateMachine.markInferencing();
      expect(stateMachine.state, RuntimeLifecycleState.inferencing);

      // On completion the machine must return to loading (the pre-inference
      // state recorded when inferenceStarted was dispatched).
      stateMachine.markInferenceCompleted();
      expect(stateMachine.state, RuntimeLifecycleState.loading);
    });

    test('verified → loading → inferencing follows full production path', () {
      final stateMachine = RuntimeStateMachine();

      stateMachine.markHealthy();
      expect(stateMachine.state, RuntimeLifecycleState.healthy);

      stateMachine.markVerified();
      expect(stateMachine.state, RuntimeLifecycleState.verified);

      // Production inference: model reload then generation start.
      stateMachine.markLoading();
      expect(stateMachine.state, RuntimeLifecycleState.loading);

      stateMachine.markInferencing();
      expect(stateMachine.state, RuntimeLifecycleState.inferencing);

      stateMachine.markInferenceCompleted();
      // Returns to loading (the state captured when inferenceStarted fired).
      expect(stateMachine.state, RuntimeLifecycleState.loading);
    });
  });
}
