import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/android_ffi_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AndroidFfiRuntimeProvider.shouldReuseRuntimeVerification', () {
    test('defines the runtime phase lifecycle markers', () {
      expect(
        RuntimePhase.values.map((phase) => phase.name).toList(),
        containsAll(<String>[
          'tokenizing',
          'startingGeneration',
          'waitingFirstToken',
          'streaming',
          'completed',
          'failed',
          'cancelled',
          'stalled',
        ]),
      );
    });

    test('promotes runtimeUnavailable snapshot to ready when reuse is valid', () {
      final stateMachine = RuntimeStateMachine();
      final provider = AndroidFfiRuntimeProvider(
        runtimeStateMachine: stateMachine,
        developerModeProvider: () => false,
      );
      const modelPath = '/tmp/runtime-model.gguf';

      provider.monitor.update(
        LocalRuntimeStatus.loading,
        message: 'loading',
      );
      provider.recordVerificationSuccess(
        modelPath: modelPath,
        source: 'test',
      );

      provider.monitor.update(
        LocalRuntimeStatus.runtimeUnavailable,
        message: 'stale pre-verified state',
      );

      final reusable = provider.shouldReuseRuntimeVerification(
        modelPath: modelPath,
      );

      expect(reusable, isTrue);
      expect(provider.monitor.state.status, LocalRuntimeStatus.ready);
      expect(stateMachine.state, RuntimeLifecycleState.verified);
    });

    test('marks lifecycle verified for non-promoted statuses when reuse is valid',
        () {
      final stateMachine = RuntimeStateMachine();
      final provider = AndroidFfiRuntimeProvider(
        runtimeStateMachine: stateMachine,
        developerModeProvider: () => false,
      );
      const modelPath = '/tmp/runtime-model-2.gguf';

      provider.monitor.update(
        LocalRuntimeStatus.loading,
        message: 'loading',
      );
      provider.recordVerificationSuccess(
        modelPath: modelPath,
        source: 'test',
      );
      stateMachine.reset();
      provider.monitor.update(
        LocalRuntimeStatus.loading,
        message: 'loading-again',
      );

      final reusable = provider.shouldReuseRuntimeVerification(
        modelPath: modelPath,
      );

      expect(reusable, isTrue);
      expect(provider.monitor.state.status, LocalRuntimeStatus.loading);
      expect(stateMachine.state, RuntimeLifecycleState.verified);
    });

    test('keeps verification when cleared while runtime is already ready', () {
      final stateMachine = RuntimeStateMachine();
      final provider = AndroidFfiRuntimeProvider(
        runtimeStateMachine: stateMachine,
        developerModeProvider: () => false,
      );
      final modelPath =
          '${Directory.systemTemp.path}/runtime-model-ready.gguf';

      provider.recordVerificationSuccess(
        modelPath: modelPath,
        source: 'test',
      );
      expect(provider.isRuntimeVerified(modelPath: modelPath), isTrue);
      provider.monitor.update(
        LocalRuntimeStatus.ready,
        message: 'ready',
      );

      provider.clearRuntimeVerification();

      expect(provider.isRuntimeVerified(modelPath: modelPath), isTrue);
      expect(provider.monitor.state.status, LocalRuntimeStatus.ready);
      expect(stateMachine.state, RuntimeLifecycleState.verified);
    });

    test('disables verification reuse after a manual reset request', () {
      final stateMachine = RuntimeStateMachine();
      final provider = AndroidFfiRuntimeProvider(
        runtimeStateMachine: stateMachine,
        developerModeProvider: () => false,
      );
      final modelPath =
          '${Directory.systemTemp.path}/runtime-model-reset.gguf';

      provider.recordVerificationSuccess(
        modelPath: modelPath,
        source: 'test',
      );
      expect(provider.isRuntimeVerified(modelPath: modelPath), isTrue);
      expect(provider.shouldReuseRuntimeVerification(modelPath: modelPath), isTrue);

      provider.requestManualVerificationReset();

      expect(provider.shouldReuseRuntimeVerification(modelPath: modelPath), isFalse);
    });
  });
}
