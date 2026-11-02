import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'hybrid_checkpoint_execution_coordinator.dart';
import 'hybrid_checkpoint_ledger.dart';
import 'hybrid_checkpoint_attempt_journal.dart';
import 'hybrid_validated_connectivity.dart';
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
    required HybridCheckpointAttemptJournal attemptJournal,
    required Future<bool> Function(String ownerId, String sessionId)
        authorizeOwnerSession,
    required Future<bool> Function() isNetworkAvailable,
    required Future<bool> Function() isLocalReady,
    required bool Function(Object error) isConnectivityFailure,
  })  : _coordinator = coordinator,
        _attemptJournal = attemptJournal,
        _authorizeOwnerSession = authorizeOwnerSession,
        _isNetworkAvailable = isNetworkAvailable,
        _isLocalReady = isLocalReady,
        _isConnectivityFailure = isConnectivityFailure;

  /// Android-only adapter to the OS validated default network snapshot.
  ///
  /// No network traffic, polling, or app-wide Chat listener is installed.
  /// The caller still supplies readiness, privacy/consent and trustworthy
  /// error classification, and must explicitly invoke run().
  factory HybridCheckpointRelay.android({
    required HybridCheckpointExecutionCoordinator coordinator,
    required HybridCheckpointAttemptJournal attemptJournal,
    required Future<bool> Function(String ownerId, String sessionId)
        authorizeOwnerSession,
    required Future<bool> Function() isLocalReady,
    required bool Function(Object error) isConnectivityFailure,
    HybridValidatedConnectivity? connectivity,
  }) {
    final network = connectivity ?? const HybridValidatedConnectivity();
    return HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: attemptJournal,
      authorizeOwnerSession: authorizeOwnerSession,
      isNetworkAvailable: network.isNetworkAvailable,
      isLocalReady: isLocalReady,
      isConnectivityFailure: isConnectivityFailure,
    );
  }

  final HybridCheckpointExecutionCoordinator _coordinator;
  final HybridCheckpointAttemptJournal _attemptJournal;

  /// A trusted production adapter must validate the active authenticated
  /// principal AND the right to access this session. Caller-provided ownerId
  /// and secure-storage fingerprints are not user authentication.
  final Future<bool> Function(String ownerId, String sessionId)
      _authorizeOwnerSession;
  final Future<bool> Function() _isNetworkAvailable;
  final Future<bool> Function() _isLocalReady;
  final bool Function(Object error) _isConnectivityFailure;
  static const Uuid _uuid = Uuid();

  // Only serializes opt-in relays inside this Dart isolate/process. It is NOT
  // a cross-process or cross-device transactional lease; the protected store
  // still needs a proper CAS/lease before enabling background multi-process
  // execution or sync.
  static final Set<String> _activeExecutions = <String>{};

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
  ///
  /// Only one relay for the same owner+execution can run within this Dart
  /// isolate at a time. An ambiguous transport failure does NOT automatically
  /// replay the interrupted step unless [allowRetryAfterConnectionLoss]
  /// explicitly certifies that the step can be retried without duplicating
  /// external side effects. Without this approval, the protected checkpoint
  /// remains unchanged for manual inspection/resume.
  Future<HybridResumableExecution> run({
    required String ownerId,
    required String executionId,
    required String sessionId,
    required bool preferCloudAtStart,
    required Future<bool> Function(int checkpoint, String result)
        validateResult,
    Future<bool> Function(String outboundText)? authorizeCloudText,
    Future<bool> Function()? keepRunning,
    Future<bool> Function(int checkpoint)? allowRetryAfterConnectionLoss,
    Future<bool> Function(int checkpoint)? allowRetryAfterUncertainRestart,
  }) async {
    final claim = jsonEncode(<String>[ownerId, executionId]);
    if (!_activeExecutions.add(claim)) {
      throw StateError('HYBRID execution already has an active relay');
    }
    try {
      return await _runClaimed(
        ownerId: ownerId,
        executionId: executionId,
        sessionId: sessionId,
        preferCloudAtStart: preferCloudAtStart,
        validateResult: validateResult,
        authorizeCloudText: authorizeCloudText,
        keepRunning: keepRunning,
        allowRetryAfterConnectionLoss: allowRetryAfterConnectionLoss,
        allowRetryAfterUncertainRestart: allowRetryAfterUncertainRestart,
      );
    } finally {
      _activeExecutions.remove(claim);
    }
  }

  Future<HybridResumableExecution> _runClaimed({
    required String ownerId,
    required String executionId,
    required String sessionId,
    required bool preferCloudAtStart,
    required Future<bool> Function(int checkpoint, String result)
        validateResult,
    Future<bool> Function(String outboundText)? authorizeCloudText,
    Future<bool> Function()? keepRunning,
    Future<bool> Function(int checkpoint)? allowRetryAfterConnectionLoss,
    Future<bool> Function(int checkpoint)? allowRetryAfterUncertainRestart,
  }) async {
    // Reject before reading protected plans, checkpoints or intent markers.
    // A rejected caller must not learn whether an execution exists.
    if (!await _authorizeOwnerSession(ownerId, sessionId)) {
      throw StateError('HYBRID owner/session is not authorized');
    }
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
    final pending = await _attemptJournal.pendingCheckpoint(
      ownerId: ownerId, executionId: executionId,
    );
    if (pending != null) {
      if (pending <= operation.ledger.completedCount) {
        await _attemptJournal.clearAfterCommit(
          ownerId: ownerId, executionId: executionId,
          completedCount: operation.ledger.completedCount,
        );
      } else if (pending == operation.nextCheckpoint) {
        if (allowRetryAfterUncertainRestart == null ||
            !await allowRetryAfterUncertainRestart(pending)) {
          throw StateError('Unconfirmed HYBRID checkpoint requires safe-retry approval');
        }
      } else {
        throw StateError('HYBRID pending step disagrees with protected progress');
      }
    }
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
      // Revocation during a previous step must block any subsequent step.
      if (!await _authorizeOwnerSession(ownerId, sessionId)) {
        throw StateError('HYBRID owner/session authorization was revoked');
      }
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
          authorizeCheckpointCommit: () =>
              _authorizeOwnerSession(ownerId, sessionId),
          markBeforeInference: () async {
            // Authentication can be revoked during the Cloud consent dialog.
            // Check again after consent and before any protected marker or
            // remote inference starts.
            if (!await _authorizeOwnerSession(ownerId, sessionId)) {
              throw StateError('HYBRID owner/session authorization was revoked');
            }
            await _attemptJournal.markBeforeInference(
              ownerId: ownerId, executionId: executionId, checkpoint: step,
            );
          },
        );
        await _attemptJournal.clearAfterCommit(
          ownerId: ownerId, executionId: executionId,
          completedCount: operation.ledger.completedCount,
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
        if (allowRetryAfterConnectionLoss == null ||
            !await allowRetryAfterConnectionLoss(step)) {
          // Interrupted Cloud work could have triggered a side effect before
          // the transport failed. A new Local attempt is allowed only when a
          // trusted caller attests to an idempotent/safe retry for this step.
          rethrow;
        }
        if (!await _isLocalReady()) {
          throw StateError('Cloud interrupted; Local model not ready');
        }
        if (!await _authorizeOwnerSession(ownerId, sessionId)) {
          throw StateError('HYBRID owner/session authorization was revoked');
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
