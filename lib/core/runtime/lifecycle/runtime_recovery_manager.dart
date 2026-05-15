import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/runtime/lifecycle/runtime_boot_manager.dart';
import 'package:ai_orchestrator/core/runtime/lifecycle/runtime_healthcheck_service.dart';
import 'package:ai_orchestrator/core/runtime/lifecycle/runtime_ready_verifier.dart';
import 'package:ai_orchestrator/core/runtime/lifecycle/runtime_state_machine.dart';
import 'package:ai_orchestrator/core/runtime/lifecycle/runtime_warmup_service.dart';

/// Orchestrates the recovery pipeline when the runtime enters a failed state.
///
/// Recovery is a two-step process:
/// 1. Force the state machine through `recovering → uninitialized` after a
///    short delay to allow in-flight resources to clean up.
/// 2. Re-run the full boot sequence via [RuntimeBootManager.boot].
///
/// The manager has no hidden state; every dependency is injected by the
/// caller so that the recovery path is fully testable.
class RuntimeRecoveryManager {
  const RuntimeRecoveryManager();

  static const Duration _recoveryCleanupDelay = Duration(milliseconds: 500);

  /// Attempts to recover the runtime by re-running the full boot sequence.
  ///
  /// Returns `true` when boot succeeds after recovery, `false` otherwise.
  Future<bool> recover({
    required RuntimeStateMachine stateMachine,
    required RuntimeBootManager bootManager,
    required String modelPath,
    required RuntimeReadyVerifier verifier,
    required RuntimeWarmupService warmupService,
    required RuntimeHealthcheckService healthcheckService,
  }) async {
    debugPrint('[RUNTIME_RECOVERY] Recovery initiated for model: $modelPath');

    // Step 1 — move into recovering state to signal intent.
    stateMachine.forceState(RuntimeLifecycleState.recovering);

    // Step 2 — brief delay to allow in-flight async operations to unwind.
    await Future<void>.delayed(_recoveryCleanupDelay);

    // Step 3 — reset to uninitialized so the boot sequence can start fresh.
    stateMachine.forceState(RuntimeLifecycleState.uninitialized);

    // Step 4 — re-run the full boot sequence.
    debugPrint('[RUNTIME_RECOVERY] Starting boot sequence after recovery');
    final result = await bootManager.boot(
      modelPath: modelPath,
      stateMachine: stateMachine,
      verifier: verifier,
      warmupService: warmupService,
      healthcheckService: healthcheckService,
    );

    if (result) {
      debugPrint('[RUNTIME_RECOVERY] Recovery complete – runtime is ready');
    } else {
      debugPrint('[RUNTIME_RECOVERY] Recovery failed – runtime is in failed state');
    }

    return result;
  }
}
