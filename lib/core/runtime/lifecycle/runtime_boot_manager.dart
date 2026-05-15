import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/runtime/lifecycle/runtime_healthcheck_service.dart';
import 'package:ai_orchestrator/core/runtime/lifecycle/runtime_ready_verifier.dart';
import 'package:ai_orchestrator/core/runtime/lifecycle/runtime_state_machine.dart';
import 'package:ai_orchestrator/core/runtime/lifecycle/runtime_warmup_service.dart';

/// Orchestrates the full runtime boot sequence.
///
/// Each step transitions the [RuntimeStateMachine] forward.  On the first
/// step that fails the machine is moved to `failed` and `false` is returned.
/// The caller is responsible for supplying all dependencies; this class has
/// no hidden singletons.
class RuntimeBootManager {
  const RuntimeBootManager();

  /// Executes the boot pipeline from `loadingModel` through to `ready`.
  ///
  /// Returns `true` when every step succeeds, `false` otherwise.
  Future<bool> boot({
    required String modelPath,
    required RuntimeStateMachine stateMachine,
    required RuntimeReadyVerifier verifier,
    required RuntimeWarmupService warmupService,
    required RuntimeHealthcheckService healthcheckService,
  }) async {
    // Step 1 – load model
    debugPrint('[RUNTIME_STATE] Boot sequence starting for model: $modelPath');
    if (!stateMachine.transition(RuntimeLifecycleState.loadingModel)) {
      return _fail(stateMachine, 'Cannot transition to loadingModel');
    }

    // Step 2 – validate model file
    if (!stateMachine.transition(RuntimeLifecycleState.validatingModel)) {
      return _fail(stateMachine, 'Cannot transition to validatingModel');
    }
    final modelResult = await verifier.validateModel(modelPath);
    if (!modelResult.isSuccess) {
      return _fail(
        stateMachine,
        'Model validation failed: ${modelResult.failureReason}',
      );
    }

    // Step 3 – initialise native runtime bridge
    if (!stateMachine.transition(RuntimeLifecycleState.initializingRuntime)) {
      return _fail(stateMachine, 'Cannot transition to initializingRuntime');
    }
    final bridgeResult = await verifier.validateNativeBridge();
    if (!bridgeResult.isSuccess) {
      return _fail(
        stateMachine,
        'Native bridge validation failed: ${bridgeResult.failureReason}',
      );
    }

    // Step 4 – initialise tokenizer
    if (!stateMachine.transition(RuntimeLifecycleState.initializingTokenizer)) {
      return _fail(stateMachine, 'Cannot transition to initializingTokenizer');
    }
    final tokenizerResult = await verifier.validateTokenizer();
    if (!tokenizerResult.isSuccess) {
      return _fail(
        stateMachine,
        'Tokenizer validation failed: ${tokenizerResult.failureReason}',
      );
    }

    // Step 5 – initialise embeddings
    if (!stateMachine.transition(
      RuntimeLifecycleState.initializingEmbeddings,
    )) {
      return _fail(
        stateMachine,
        'Cannot transition to initializingEmbeddings',
      );
    }
    final embeddingsResult = await verifier.validateEmbeddings();
    if (!embeddingsResult.isSuccess) {
      return _fail(
        stateMachine,
        'Embeddings validation failed: ${embeddingsResult.failureReason}',
      );
    }

    // Step 6 – allocate context
    if (!stateMachine.transition(RuntimeLifecycleState.allocatingContext)) {
      return _fail(stateMachine, 'Cannot transition to allocatingContext');
    }
    final ctxResult = await verifier.validateContextAllocation();
    if (!ctxResult.isSuccess) {
      return _fail(
        stateMachine,
        'Context allocation failed: ${ctxResult.failureReason}',
      );
    }

    // Step 7 – warm-up
    if (!stateMachine.transition(RuntimeLifecycleState.warmingUp)) {
      return _fail(stateMachine, 'Cannot transition to warmingUp');
    }
    final warmupOk = await warmupService.runWarmup(modelPath);
    if (!warmupOk) {
      return _fail(stateMachine, 'Warmup dry-run failed');
    }

    // Step 8 – health check
    if (!stateMachine.transition(RuntimeLifecycleState.runningHealthcheck)) {
      return _fail(stateMachine, 'Cannot transition to runningHealthcheck');
    }
    final health = await healthcheckService.runHealthcheck();
    if (!health.isHealthy) {
      return _fail(
        stateMachine,
        'Healthcheck failed: ${health.details}',
      );
    }

    // Step 9 – ready
    if (!stateMachine.transition(RuntimeLifecycleState.ready)) {
      return _fail(stateMachine, 'Cannot transition to ready');
    }
    debugPrint('[RUNTIME_READY] Boot complete. Runtime is ready.');
    return true;
  }

  bool _fail(RuntimeStateMachine stateMachine, String reason) {
    debugPrint('[RUNTIME_STATE] Boot failed: $reason');
    stateMachine.transition(RuntimeLifecycleState.failed);
    return false;
  }
}
