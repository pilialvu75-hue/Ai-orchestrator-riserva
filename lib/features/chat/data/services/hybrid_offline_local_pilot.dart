import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_attempt_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_execution_coordinator.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_plan_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_relay.dart';

import 'hybrid_local_session_authorizer.dart';

/// Explicit LOCAL-only pilot harness for the checkpoint relay.
///
/// No production Chat integration, route switch, remote identity, network
/// discovery, cloud consent or cloud model invocation is performed here.
/// Even if the host device is online, this harness only dispatches Local
/// inference. Never invoke it automatically while opening a conversation.
///
/// Enrollment is a separate, explicit caller action:
/// [HybridLocalSessionAuthorizer.initializeLocalOwner]. This class NEVER
/// creates an owner, account or conversation in the background.
///
/// This single-profile device identity is not authentication for Cloud data
/// disclosure, multi-user sharing or cross-device sync.
final class HybridOfflineLocalPilot {
  HybridOfflineLocalPilot({
    required HybridLocalSessionAuthorizer localAuthorizer,
    required HybridCheckpointExecutionCoordinator coordinator,
    required HybridCheckpointAttemptJournal attemptJournal,
    required Future<bool> Function() isLocalReady,
  })  : _localAuthorizer = localAuthorizer,
        _coordinator = coordinator,
        _relay = HybridCheckpointRelay(
          coordinator: coordinator,
          attemptJournal: attemptJournal,
          authorizeOwnerSession: localAuthorizer.authorizeOwnerSession,
          isNetworkAvailable: _alwaysOffline,
          isLocalReady: isLocalReady,
          isConnectivityFailure: _neverConnectivityFallback,
        );

  final HybridLocalSessionAuthorizer _localAuthorizer;
  final HybridCheckpointExecutionCoordinator _coordinator;
  final HybridCheckpointRelay _relay;

  static Future<bool> _alwaysOffline() async => false;
  static bool _neverConnectivityFallback(Object _) => false;

  /// The caller must explicitly enroll the owner and create the chat first.
  /// Deny registration for absent/trashed sessions and mismatched owners.
  Future<HybridResumableExecution> register({
    required String ownerId,
    required HybridCheckpointPlan plan,
  }) async {
    if (!await _localAuthorizer.authorizeOwnerSession(
      ownerId, plan.sessionId,
    )) {
      throw StateError('HYBRID local pilot owner/session is not authorized');
    }
    return _coordinator.create(ownerId: ownerId, plan: plan);
  }

  /// Runs only Local checkpoints. A caller-supplied independent validator is
  /// mandatory, and earlier unconfirmed work NEVER auto-replays after restart.
  /// This harness has no API for enabling Cloud or bypassing crash-retry gates.
  Future<HybridResumableExecution> resumeLocal({
    required String ownerId,
    required String sessionId,
    required String executionId,
    required Future<bool> Function(int checkpoint, String result) validateResult,
    Future<bool> Function()? keepRunning,
    Future<bool> Function()? isCancellationRequested,
  }) => _relay.run(
        ownerId: ownerId,
        sessionId: sessionId,
        executionId: executionId,
        preferCloudAtStart: false,
        validateResult: validateResult,
        keepRunning: keepRunning,
        isCancellationRequested: isCancellationRequested,
      );
}
