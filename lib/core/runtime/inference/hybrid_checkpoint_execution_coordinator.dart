import 'hybrid_checkpoint_ledger.dart';
import 'hybrid_checkpoint_plan_store.dart';
import 'hybrid_checkpoint_snapshot_store.dart';
import 'hybrid_checkpoint_step_runner.dart';

/// A plan and its saved progress loaded as a single logical operation.
final class HybridResumableExecution {
  HybridResumableExecution({
    required this.plan,
    required this.ledger,
  }) {
    plan.verifyLedger(ledger);
  }

  final HybridCheckpointPlan plan;
  final HybridCheckpointLedger ledger;

  int get nextCheckpoint => ledger.nextCheckpoint;
  bool get isComplete => ledger.isComplete;
}

/// Explicit, opt-in coordinator for the HYBRID Assistant.
/// 
/// It does NOT attach to ordinary Chat automatically. The production owner
/// identity, network listener, consent UI, plan validator and model readiness
/// must be supplied externally before connecting it to the app.
///
/// Plan is saved before the initial empty progress snapshot. After a process
/// crash between these two writes, [resume] fails closed, and [create] can
/// complete the initial registration with the same immutable plan. No Cloud
/// call or replay takes place during restore.
final class HybridCheckpointExecutionCoordinator {
  HybridCheckpointExecutionCoordinator({
    required HybridCheckpointPlanStore planStore,
    required HybridCheckpointSnapshotStore snapshotStore,
    required HybridCheckpointStepRunner stepRunner,
  })  : _plans = planStore,
        _snapshots = snapshotStore,
        _runner = stepRunner;

  final HybridCheckpointPlanStore _plans;
  final HybridCheckpointSnapshotStore _snapshots;
  final HybridCheckpointStepRunner _runner;

  Future<HybridResumableExecution> create({
    required String ownerId,
    required HybridCheckpointPlan plan,
  }) async {
    await _plans.save(ownerId: ownerId, plan: plan);
    final existing = await _snapshots.load(
      ownerId: ownerId,
      executionId: plan.executionId,
    );
    if (existing != null) {
      plan.verifyLedger(existing);
      if (existing.completedCount != 0) {
        throw StateError('HYBRID execution has already started; use resume');
      }
      return HybridResumableExecution(plan: plan, ledger: existing);
    }

    final ledger = HybridCheckpointLedger(
      executionId: plan.executionId,
      totalCheckpoints: plan.totalCheckpoints,
    );
    await _snapshots.saveSnapshot(
      ownerId: ownerId,
      snapshot: ledger.toJson(),
    );
    return HybridResumableExecution(plan: plan, ledger: ledger);
  }

  /// Restores both owner-scoped entries. Missing plan/results are not guessed.
  Future<HybridResumableExecution?> resume({
    required String ownerId,
    required String executionId,
  }) async {
    final plan = await _plans.load(
      ownerId: ownerId,
      executionId: executionId,
    );
    final ledger = await _snapshots.load(
      ownerId: ownerId,
      executionId: executionId,
    );
    if (plan == null && ledger == null) return null;
    if (plan == null || ledger == null) {
      throw StateError('HYBRID execution is only partially registered');
    }
    return HybridResumableExecution(plan: plan, ledger: ledger);
  }

  /// Existing InferenceService is used through [HybridCheckpointStepRunner].
  /// A restored execution begins a NEW Attempt with [ledger.beginAttempt].
  /// The coordinator never decides a Cloud handback automatically.
  Future<String> executeNext({
    required String ownerId,
    required HybridResumableExecution execution,
    required HybridAttemptLease lease,
    required String sessionId,
    required bool isOffline,
    required Future<bool> Function(String result) validateResult,
    Future<bool> Function(String outboundText)? authorizeCloudText,
  }) async {
    execution.plan.verifyLedger(execution.ledger);
    return _runner.executeNext(
      ownerId: ownerId,
      ledger: execution.ledger,
      lease: lease,
      sessionId: sessionId,
      stepInstruction:
          execution.plan.instructionFor(execution.ledger.nextCheckpoint),
      isOffline: isOffline,
      validateResult: validateResult,
      authorizeCloudText: authorizeCloudText,
    );
  }
}
