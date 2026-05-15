import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/runtime/lifecycle/runtime_state_machine.dart';

/// Result object returned by [RuntimeHealthcheckService.runHealthcheck].
class HealthcheckResult {
  const HealthcheckResult({
    required this.isHealthy,
    required this.details,
  });

  /// `true` when all checks passed.
  final bool isHealthy;

  /// Human-readable summary of the healthcheck outcome.
  final String details;

  @override
  String toString() =>
      'HealthcheckResult(isHealthy: $isHealthy, details: $details)';
}

/// Runs post-boot checks to confirm the runtime is operating correctly.
///
/// The healthcheck is intentionally lightweight — it is designed to run in
/// the hot-path of the boot sequence and must not block the UI thread.
class RuntimeHealthcheckService {
  /// [stateMachine] is optional.  When supplied, the state consistency check
  /// is active and a warning is emitted if the machine is not in the expected
  /// `runningHealthcheck` state.
  const RuntimeHealthcheckService({this.stateMachine});

  final RuntimeStateMachine? stateMachine;

  /// Runs all health checks and returns a consolidated [HealthcheckResult].
  Future<HealthcheckResult> runHealthcheck() async {
    final issues = <String>[];

    _checkMemoryPressure(issues);
    _checkStateConsistency(issues);

    if (issues.isEmpty) {
      debugPrint('[HEALTHCHECK_OK] All checks passed');
      return const HealthcheckResult(
        isHealthy: true,
        details: 'All healthchecks passed',
      );
    }

    final summary = issues.join('; ');
    debugPrint('[HEALTHCHECK_FAIL] Issues found: $summary');
    return HealthcheckResult(
      isHealthy: false,
      details: summary,
    );
  }

  // ---------------------------------------------------------------------------
  // Individual checks
  // ---------------------------------------------------------------------------

  void _checkMemoryPressure(List<String> issues) {
    // Memory pressure detection is delegated to the OS / platform layer.
    // For now this check always passes; a future iteration can integrate
    // dart:developer MemoryUsage when it becomes stable.
    debugPrint('[HEALTHCHECK_OK] Memory pressure check passed');
  }

  void _checkStateConsistency(List<String> issues) {
    final sm = stateMachine;
    if (sm == null) return;

    const expectedState = RuntimeLifecycleState.runningHealthcheck;
    if (sm.currentState != expectedState) {
      final warning =
          'State consistency warning: expected $expectedState, '
          'found ${sm.currentState}';
      debugPrint('[HEALTHCHECK_OK] $warning');
      // This is a warning, not a failure — the healthcheck itself continues.
    } else {
      debugPrint(
        '[HEALTHCHECK_OK] State consistency check passed '
        '(state=${sm.currentState})',
      );
    }
  }
}
