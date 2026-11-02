import 'package:uuid/uuid.dart';

import 'hybrid_checkpoint_execution_coordinator.dart';
import 'hybrid_checkpoint_ledger.dart';
import 'hybrid_checkpoint_step_runner.dart';
import 'inference_response.dart';

/// Explicit, opt-in network-aware relay for one Assistant HYBRID execution.
///
/// No connectivity plugin is loaded here, no UI/Chat route is silently changed,
/// and the Cantiere is not involved. The owner provides the live network
/// indicator, Local readiness check, consent and independent validation.
///
/// Switching to Local at a checkpoint boundary is safe only after verifying
/// its readiness. An interrupted Cloud step is eligible for retry locally ONLY
/// when a trusted caller classifies the error as a connectivity failure AND
/// the network is now unavailable. Other failures fail closed.
///
/// This cannot recover provider-private reasoning or unreturned output.
/// The caller must ensure that steps with external side effects are idempotent
/// before allowing retries after an ambiguous transport failure.
final class HybridCheckpointRelay {
  HybridCheckpointRelay({
    required HybridCheckpointExecutionCoordinator coordinator,
    required Future<bool> Function() isNetworkAvailable,
    required Future<bool> Function() isLocalReady,
    required bool Function(Object error) isConnectivityFailure,
  })  : _coordinator = coordinator,
        _isNetworkAvailable = isNetworkAvailable,
        _isLocalReady = isLocalReady,
        _isConnectivityFailure = isConnectivityFailure;

  final HybridCheckpointExecutionCoordinator _coordinator;
  final Future<bool> Function() _isNetworkAvailable;
  final Future<bool> Function() _isLocalReady;
  final bool Function(Object error) _isConnectivityFailure;
  static const Uuid _uuid = Uuid();

  /// Executes a previously registered, protected plan step by step.
  ///
  /// Network reconnection does NOT automatically transfer an active Local
  /// attempt to Cloud. If an interrupted execution last used Local, restart
  /// continues in Local by default, even when online.
  ///
  /// [preferCloudAtStart] applies only to a new execution or an execution
  /// whose last completed step was Cloud. It does not override a Local resume.
  ///
  /// The caller may stop the workflow between checkpoints using [keepRunning].
  /// Stopping does not delete protected plans or results.
  Future<HybridResumableExecution> run({
    required String ownerId,
    required String executionId,
    required String sessionId,
    required bool preferCloudAtStart,
    required Future<bool> Function(int checkpoint, String result)
        validateResult,
    Future<bool> Function(String outboundText)? authorizeCloudText,
    Future<bool> Function()? keepRunning,
  }) async {
    final restored = await _coordinator.resume(
      ownerId: ownerId,
      executionId: executionId,
    );
    if (restored == null) {
      throw StateError('HYBRID plan and checkpoints must be registered first');
    }
    // The relay needs a non-nullable variable across the async loop. A new
    // snapshot is always loaded before ownership changes or retries.
    HybridResumableExecution operation = restored;
    if (operation.isComplete) return operation;

    final lastExecutor = operation.ledger.completed.isNotEmpty
        ? operation.ledger.completed.last.executor
        : null;
    var executor = lastExecutor == HybridCheckpointExecutor.local
        ? HybridCheckpointExecutor.local
        : (preferCloudAtStart && await _isNetworkAvailable()
            ? HybridCheckpointExecutor.cloud
            : HybridCheckpointExecutor.local);
    HybridAttemptLease? lease;

    while (!operation.isComplete) {
      if (keepRunning != null && !await keepRunning()) {
        // Do not start another checkpoint; the protected progress is retained.
        return operation;
      }
      final online = await _isNetworkAvailable();
      if (executor == HybridCheckpointExecutor.cloud && !online) {
        // A connectivity change at a checkpoint boundary never needs Cloud.
        if (!await _isLocalReady()) {
          throw StateError('Network lost; Local model not ready');
        }
        if (lease != null) {
          operation.ledger.interruptAttempt(lease);
          lease = null;
        }
        // Re-read the protected store: it is authoritative after every
        // failure, cancellation and attempted write.
        operation = (await _coordinator.resume(
          ownerId: ownerId,
          executionId: executionId,
        ))!;
        executor = HybridCheckpointExecutor.local;
      }
      if (executor == HybridCheckpointExecutor.local &&
          !await _isLocalReady()) {
        throw StateError('Local model is not ready for HYBRID relay');
      }
      lease ??= operation.ledger.beginAttempt(
        attemptId:
            'hybrid-${executor.name}-${operation.nextCheckpoint}-${_uuid.v4()}',
        executor: executor,
      );

      final step = operation.nextCheckpoint;
      try {
        await _coordinator.executeNext(
          ownerId: ownerId,
          execution: operation,
          lease: lease,
          sessionId: sessionId,
          isOffline: !online,
          validateResult: (output) => validateResult(step, output),
          authorizeCloudText: authorizeCloudText,
        );
      } catch (error) {
        // Only a trusted transport classification AND confirmed network loss
        // permit one fallback. No automatic retry on validation, consent,
        // spending, cancellation or data-integrity failures.
        if (executor != HybridCheckpointExecutor.cloud ||
            (error is HybridCheckpointStreamFailure &&
                error.terminalState == InferenceTerminalState.cancelled) ||
            !_isConnectivityFailure(error) ||
            await _isNetworkAvailable()) {
          rethrow;
        }
        if (!await _isLocalReady()) {
          throw StateError('Cloud interrupted; Local model not ready');
        }
        operation = (await _coordinator.resume(
          ownerId: ownerId,
          executionId: executionId,
        ))!;
        if (operation.isComplete) return operation;
        lease = null;
        executor = HybridCheckpointExecutor.local;
      }
    }
    return operation;
  }
}
