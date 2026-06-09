import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/android_ffi_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal GGUF header bytes used to create a valid local model fixture.
const List<int> ggufMagicHeader = <int>[
  0x47, // G
  0x47, // G
  0x55, // U
  0x46, // F
  0x00, // format version major
  0x01, // format version minor
];

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
      final modelPath = 'test-fixtures/runtime-model-ready.gguf';

      provider.recordVerificationSuccess(
        modelPath: modelPath,
        source: 'test',
      );
      expect(provider.isRuntimeVerified(modelPath: modelPath), isTrue);
      provider.monitor.update(
        LocalRuntimeStatus.ready,
        message: 'ready',
      );

      provider.clearRuntimeVerificationForTesting();

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
      const modelPath = 'test-fixtures/runtime-model-reset.gguf';

      provider.recordVerificationSuccess(
        modelPath: modelPath,
        source: 'test',
      );
      expect(provider.isRuntimeVerified(modelPath: modelPath), isTrue);
      expect(provider.shouldReuseRuntimeVerification(modelPath: modelPath), isTrue);

      provider.requestManualVerificationReset();

      expect(provider.shouldReuseRuntimeVerification(modelPath: modelPath), isFalse);
    });

    test(
      'dispatches streamInference through the Android override when typed as LocalRuntimeProvider',
      () async {
        final provider = AndroidFfiRuntimeProvider(
          developerModeProvider: () => false,
        );
        final LocalRuntimeProvider providerAsBase = provider;
        final tempDir = await Directory.systemTemp.createTemp('android-dispatch-');
        final modelFile = File('${tempDir.path}/model.gguf');
        await modelFile.writeAsBytes(ggufMagicHeader);
        addTearDown(() async {
          await tempDir.delete(recursive: true);
        });
        RuntimeEventLog.instance.clear();
        addTearDown(RuntimeEventLog.instance.clear);

        final chunks = await providerAsBase
            .streamInference(
              request: InferenceRequest(
                sessionId: 'dispatch-check',
                prompt: 'hello',
                modelId: 'unsupported_android_model',
                modelPath: modelFile.path,
              ),
              cancellationToken: CancellationToken(),
            )
            .toList();

        expect(
          RuntimeEventLog.instance.entries.any(
            (entry) => entry.message.contains('[FORENSIC_PROVIDER_ENTRY]'),
          ),
          isTrue,
        );
        expect(chunks, isNotEmpty);
        expect(chunks.last.isError, isTrue);
        expect(
          chunks.last.errorMessage,
          contains('Android local runtime'),
        );
      },
    );
  });
}
