import 'package:ai_orchestrator/core/runtime/inference/android_ffi_runtime_provider.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AndroidFfiRuntimeProvider.shouldReuseRuntimeVerification', () {
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
  });

  group('AndroidFfiRuntimeProvider.supportsModel', () {
    test('accepts downloaded GGUF model outside validated catalog', () {
      final provider = AndroidFfiRuntimeProvider(
        developerModeProvider: () => false,
      );
      const model = AiModel(
        id: 'tinyllama_1_1b_chat',
        displayName: 'TinyLlama 1.1B',
        fileName: 'tinyllama.gguf',
        downloadUrl: 'https://example.com/tinyllama.gguf',
        version: '1.0.0',
        sizeBytes: 123456789,
        description: 'custom gguf',
        isDownloaded: true,
        localPath: '/tmp/tinyllama.gguf',
        validationStatus: ModelValidationStatus.invalidModel,
      );

      expect(provider.supportsModel(model), isTrue);
    });
  });
}
