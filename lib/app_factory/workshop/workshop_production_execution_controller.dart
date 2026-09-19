import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_execution.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_validated_proposal_snapshot.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_workspace_proposal_applier.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

enum WorkshopProductionExecutionStatus {
  idle,
  running,
  cancelling,
  succeeded,
  failed,
  cancelled,
}

enum WorkshopBuildRepairReservation {
  reserved,
  budgetExhausted,
  repeatedFailure,
}

enum WorkshopProductionExecutionRecoveryDisposition {
  validatedApprovalRecovered,
  safeReplayPending,
  retryAvailable,
  cancelled,
}

final class WorkshopProductionExecutionRecovery {
  const WorkshopProductionExecutionRecovery({
    required this.execution,
    required this.disposition,
  });

  final WorkshopExecution execution;
  final WorkshopProductionExecutionRecoveryDisposition disposition;
}

final class WorkshopProductionExecutionPolicy {
  const WorkshopProductionExecutionPolicy({
    this.maxDistinctTasksPerProject = 64,
    this.maxBuildRepairAttempts = 2,
  })  : assert(maxDistinctTasksPerProject > 0),
        assert(maxBuildRepairAttempts >= 0);

  /// Hard guard against malformed/cyclic plans causing unbounded unattended
  /// execution. Retries of the same authoritative task do not consume a new
  /// slot; a new project automatically starts with a fresh budget.
  final int maxDistinctTasksPerProject;

  /// Hard upper bound for project-code build repair productions belonging to
  /// one logical repair chain. Infrastructure failures never consume this
  /// budget because they are not eligible for AI repair.
  final int maxBuildRepairAttempts;
}

final class WorkshopProductionExecutionState {
  const WorkshopProductionExecutionState({
    this.status = WorkshopProductionExecutionStatus.idle,
    this.handle,
    this.result,
    this.error,
    this.startedAt,
    this.finishedAt,
    this.isOffline = false,
  });

  final WorkshopProductionExecutionStatus status;
  final WorkshopProductionTaskHandle? handle;
  final WorkshopTaskInferenceResult? result;
  final Object? error;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// Execution mode captured when this task attempt started. Retry preserves
  /// this value so an explicitly offline task can never silently become online.
  final bool isOffline;

  bool get isRunning =>
      status == WorkshopProductionExecutionStatus.running ||
      status == WorkshopProductionExecutionStatus.cancelling;

  bool get hasResult => result != null;

  bool get canRetry =>
      status == WorkshopProductionExecutionStatus.failed ||
      status == WorkshopProductionExecutionStatus.cancelled;

  WorkshopProductionExecutionState copyWith({
    WorkshopProductionExecutionStatus? status,
    WorkshopProductionTaskHandle? handle,
    WorkshopTaskInferenceResult? result,
    Object? error,
    DateTime? startedAt,
    DateTime? finishedAt,
    bool? isOffline,
    bool clearResult = false,
    bool clearError = false,
    bool clearFinishedAt = false,
  }) {
    return WorkshopProductionExecutionState(
      status: status ?? this.status,
      handle: handle ?? this.handle,
      result: clearResult ? null : result ?? this.result,
      error: clearError ? null : error ?? this.error,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: clearFinishedAt ? null : finishedAt ?? this.finishedAt,
      isOffline: isOffline ?? this.isOffline,
    );
  }
}

/// Minimal seam between the long-running task execution lifecycle and the
/// production coordinator. Keeping this interface narrow lets the lifecycle be
/// owned outside the page without duplicating Workshop inference logic.
abstract interface class WorkshopProductionExecutionRunner {
  WorkshopProductionTaskHandle preparedHandle();

  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  });
}

final class WorkshopProductionTaskExecutionRunner
    implements WorkshopProductionExecutionRunner {
  const WorkshopProductionTaskExecutionRunner({
    required WorkshopProductionTaskCoordinator coordinator,
  }) : _coordinator = coordinator;

  final WorkshopProductionTaskCoordinator _coordinator;

  @override
  WorkshopProductionTaskHandle preparedHandle() =>
      _coordinator.preparedHandle();

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) {
    return _coordinator.runPrepared(
      handle: handle,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );
  }
}

/// Owns one long-running Cantiere task execution independently from widgets.
///
/// A page may attach/detach listeners without owning the task itself. The
/// controller never approves or applies changes: after inference succeeds, the
/// existing Reviewer/validation/owner approval/apply gates remain authoritative.
///
/// The controller also owns the bounded per-project task-attempt guard because
/// this state must survive page rebuilds. A retry of the same task is allowed;
/// only newly observed authoritative task ids consume the project budget.
final class WorkshopProductionExecutionController extends ChangeNotifier {
  WorkshopProductionExecutionController({
    required WorkshopProductionExecutionRunner runner,
    this.policy = const WorkshopProductionExecutionPolicy(),
    WorkshopExecutionStore? executionStore,
    WorkshopValidatedProposalSnapshotService? validatedProposalSnapshotService,
    WorkshopWorkspaceProposalApplier proposalApplier =
        const WorkshopWorkspaceProposalApplier(),
  })  : _runner = runner,
        _executionStore = executionStore,
        _validatedProposalSnapshotService = validatedProposalSnapshotService,
        _proposalApplier = proposalApplier;

  final WorkshopProductionExecutionRunner _runner;
  final WorkshopProductionExecutionPolicy policy;
  final WorkshopExecutionStore? _executionStore;
  final WorkshopValidatedProposalSnapshotService?
      _validatedProposalSnapshotService;
  final WorkshopWorkspaceProposalApplier _proposalApplier;

  WorkshopProductionExecutionState _state =
      const WorkshopProductionExecutionState();
  CancellationToken? _cancellationToken;
  Future<WorkshopTaskInferenceResult>? _activeRun;
  bool _disposed = false;
  String? _activePlanId;
  final Set<String> _startedTaskIds = <String>{};
  String? _buildRepairRootProjectId;
  String? _lastBuildRepairFailureSignature;
  int _buildRepairAttempts = 0;
  WorkshopExecution? _journalExecution;
  Object? _executionJournalError;
  Object? _recoverySnapshotError;
  bool _restartReplayPending = false;

  WorkshopProductionExecutionState get state => _state;

  int get distinctTasksStartedInCurrentProject => _startedTaskIds.length;
  int get buildRepairAttempts => _buildRepairAttempts;
  String? get buildRepairRootProjectId => _buildRepairRootProjectId;
  String? get lastBuildRepairFailureSignature =>
      _lastBuildRepairFailureSignature;
  WorkshopExecution? get journalExecution => _journalExecution;
  Object? get executionJournalError => _executionJournalError;
  Object? get recoverySnapshotError => _recoverySnapshotError;
  bool get restartReplayPending => _restartReplayPending;

  /// Reattaches the durable Execution/Attempt journal to the task that the
  /// Dashboard has already restored from its production checkpoint.
  ///
  /// An integrity-checked validated proposal snapshot can reconstruct the
  /// approval-ready VirtualWorkspace without rerunning inference. Owner apply
  /// approval is never restored. If the snapshot is absent, stale or invalid,
  /// the same logical Execution falls back to safe replay using a new Attempt.
  /// Failed/cancelled attempts remain explicit retry states. A completed
  /// Execution paired with an active recovered task is rejected fail-closed:
  /// replaying it could duplicate an already-applied mutation.
  Future<WorkshopProductionExecutionRecovery?>
      restorePersistentExecutionForPreparedTask() async {
    _ensureAvailable();
    if (_activeRun != null) {
      throw StateError(
        'Cannot restore Workshop execution identity while a task is running.',
      );
    }

    final store = _executionStore;
    if (store == null) return null;

    final handle = _runner.preparedHandle();
    final projectId = handle.plan.id.trim();
    final taskId = handle.taskId.trim();
    final expectedSessionId = 'production:$projectId:$taskId';
    final executions = await store.loadForTask(taskId);

    WorkshopExecution? recovered;
    for (final execution in executions) {
      if (execution.projectId == projectId &&
          execution.sessionId == expectedSessionId) {
        recovered = execution;
        break;
      }
    }
    if (recovered == null) return null;

    if (recovered.status == WorkshopExecutionStatus.completed) {
      throw StateError(
        'Recovered Workshop execution "${recovered.executionId}" is already '
        'completed while task "$taskId" is still active. Automatic replay is '
        'blocked to prevent a duplicate guarded apply.',
      );
    }

    _journalExecution = recovered;
    _executionJournalError = null;
    _activePlanId = projectId;
    _startedTaskIds
      ..clear()
      ..addAll(
        handle.plan.tasks
            .where((task) => task.completed)
            .map((task) => task.id.trim())
            .where((id) => id.isNotEmpty),
      )
      ..add(taskId);

    final isOffline = recovered.metadata['offline'] == true;

    if (recovered.status == WorkshopExecutionStatus.waitingApproval ||
        recovered.status == WorkshopExecutionStatus.checkpointed) {
      final restoredResult = await _tryRestoreValidatedApproval(
        handle: handle,
        execution: recovered,
      );
      if (restoredResult != null) {
        _restartReplayPending = false;
        _setState(
          WorkshopProductionExecutionState(
            status: WorkshopProductionExecutionStatus.succeeded,
            handle: handle,
            result: restoredResult,
            startedAt: recovered.startedAt,
            finishedAt: recovered.updatedAt,
            isOffline: isOffline,
          ),
        );
        return WorkshopProductionExecutionRecovery(
          execution: recovered,
          disposition: WorkshopProductionExecutionRecoveryDisposition
              .validatedApprovalRecovered,
        );
      }
    }

    switch (recovered.status) {
      case WorkshopExecutionStatus.created:
      case WorkshopExecutionStatus.running:
      case WorkshopExecutionStatus.checkpointed:
      case WorkshopExecutionStatus.waitingApproval:
        _restartReplayPending = true;
        _setState(WorkshopProductionExecutionState(isOffline: isOffline));
        return WorkshopProductionExecutionRecovery(
          execution: recovered,
          disposition:
              WorkshopProductionExecutionRecoveryDisposition.safeReplayPending,
        );
      case WorkshopExecutionStatus.failed:
        _restartReplayPending = false;
        _setState(
          WorkshopProductionExecutionState(
            status: WorkshopProductionExecutionStatus.failed,
            handle: handle,
            startedAt: recovered.startedAt,
            finishedAt: recovered.updatedAt,
            isOffline: isOffline,
          ),
        );
        return WorkshopProductionExecutionRecovery(
          execution: recovered,
          disposition:
              WorkshopProductionExecutionRecoveryDisposition.retryAvailable,
        );
      case WorkshopExecutionStatus.cancelled:
        _restartReplayPending = false;
        _setState(
          WorkshopProductionExecutionState(
            status: WorkshopProductionExecutionStatus.cancelled,
            handle: handle,
            startedAt: recovered.startedAt,
            finishedAt: recovered.updatedAt,
            isOffline: isOffline,
          ),
        );
        return WorkshopProductionExecutionRecovery(
          execution: recovered,
          disposition:
              WorkshopProductionExecutionRecoveryDisposition.cancelled,
        );
      case WorkshopExecutionStatus.completed:
        throw StateError(
          'Completed Workshop execution reached an unreachable recovery path.',
        );
    }
  }

  Future<WorkshopTaskInferenceResult?> _tryRestoreValidatedApproval({
    required WorkshopProductionTaskHandle handle,
    required WorkshopExecution execution,
  }) async {
    final service = _validatedProposalSnapshotService;
    if (service == null ||
        execution.metadata['validatedProposalSnapshot'] == null) {
      return null;
    }

    try {
      final snapshot =
          WorkshopValidatedProposalSnapshot.fromExecutionMetadata(
        execution.metadata,
      );
      final requestId = handle.session.context.request.id.trim();
      if (snapshot.executionId != execution.executionId ||
          snapshot.attemptId != execution.attemptId ||
          snapshot.projectId != execution.projectId ||
          snapshot.taskId != execution.taskId ||
          snapshot.requestId != requestId) {
        throw const FormatException(
          'Validated proposal snapshot identity does not match the '
          'authoritative Workshop execution.',
        );
      }

      final result = await service.restore(
        snapshot: snapshot,
        currentBaselineSnapshot: handle.session.workspace.originalSnapshot,
      );
      if (!result.readyForApproval ||
          !result.review.approved ||
          result.validation?.valid != true ||
          result.proposal.isEmpty) {
        throw StateError(
          'Recovered Workshop proposal is not approval-ready.',
        );
      }

      try {
        _proposalApplier.applyProposal(
          session: handle.session,
          proposal: result.proposal,
        );
        handle.session.beginReview();
        handle.session.beginValidation();
        if (handle.session.isApplyApproved) {
          throw StateError(
            'Recovered Workshop proposal must require fresh owner approval.',
          );
        }
      } catch (_) {
        if (handle.session.workspace.isInitialized) {
          handle.session.revertAll();
        }
        rethrow;
      }

      _recoverySnapshotError = null;
      return result;
    } catch (error) {
      if (handle.session.workspace.isInitialized &&
          handle.session.hasChanges) {
        try {
          handle.session.revertAll();
        } catch (_) {
          // The snapshot is already rejected. Safe replay remains authoritative.
        }
      }
      _recoverySnapshotError = error;
      return null;
    }
  }

  Future<WorkshopTaskInferenceResult> start({bool isOffline = false}) {
    return _start(isOffline: isOffline, isRetry: false);
  }

  Future<WorkshopTaskInferenceResult> _start({
    required bool isOffline,
    required bool isRetry,
  }) {
    _ensureAvailable();

    final activeRun = _activeRun;
    if (activeRun != null) {
      return activeRun;
    }

    final handle = _runner.preparedHandle();
    _registerPreparedTask(handle);

    final token = CancellationToken();
    _cancellationToken = token;

    _setState(
      WorkshopProductionExecutionState(
        status: WorkshopProductionExecutionStatus.running,
        handle: handle,
        startedAt: DateTime.now().toUtc(),
        isOffline: isOffline,
      ),
    );

    final isRestartResume = _restartReplayPending &&
        _journalExecution?.projectId == handle.plan.id &&
        _journalExecution?.taskId == handle.taskId;

    final run = _execute(
      handle,
      token,
      isOffline: isOffline,
      isRetry: isRetry || isRestartResume,
      isRestartResume: isRestartResume,
    );
    _activeRun = run;
    return run;
  }

  /// Restarts a terminal failed/cancelled execution using the coordinator's
  /// currently prepared task. This deliberately does not retry successful or
  /// still-running work, preventing duplicate inference/apply chains.
  ///
  /// The original offline/online decision is preserved across retry.
  Future<WorkshopTaskInferenceResult> retry() {
    _ensureAvailable();
    if (_activeRun != null) {
      return _activeRun!;
    }
    if (!_state.canRetry) {
      throw StateError(
        'Workshop production execution can only retry after failure or cancellation.',
      );
    }
    final isOffline = _state.isOffline;
    _setState(WorkshopProductionExecutionState(isOffline: isOffline));
    return _start(isOffline: isOffline, isRetry: true);
  }

  void cancel() {
    _ensureAvailable();

    final token = _cancellationToken;
    if (token == null || token.isCancelled || _activeRun == null) {
      return;
    }

    _setState(
      _state.copyWith(
        status: WorkshopProductionExecutionStatus.cancelling,
        clearError: true,
      ),
    );
    token.cancel();
  }

  /// Cancels the currently running task and waits until the controller has
  /// reached its terminal cancellation boundary.
  ///
  /// Project/conversation switching must never drop a live inference future
  /// and immediately reuse the same production controller for another project.
  /// The runner may surface an error while observing cancellation; that error is
  /// intentionally swallowed here because the authoritative controller state
  /// records cancellation and the caller is closing the project.
  Future<void> cancelAndWait() async {
    _ensureAvailable();

    final activeRun = _activeRun;
    if (activeRun == null) {
      return;
    }

    cancel();

    try {
      await activeRun;
    } catch (_) {
      // Cancellation can surface through the provider as an error. The state
      // transition performed by _execute remains authoritative.
    }
  }

  /// Reserves one bounded AI build-repair attempt for [rootProjectId].
  ///
  /// A new root project starts a fresh repair budget. Subsequent repair projects
  /// in the same chain must keep passing the original root id so navigation or
  /// a new repair-plan id cannot silently reset the limit. Repeating the exact
  /// same privacy-preserving failure signature stops before consuming another
  /// attempt, preventing a deterministic repair loop.
  WorkshopBuildRepairReservation reserveBuildRepairAttempt({
    required String rootProjectId,
    required String failureSignature,
  }) {
    _ensureAvailable();
    final normalizedRoot = rootProjectId.trim();
    final normalizedSignature = failureSignature.trim();
    if (normalizedRoot.isEmpty) {
      throw ArgumentError.value(
        rootProjectId,
        'rootProjectId',
        'Workshop build repair root project id cannot be empty.',
      );
    }
    if (normalizedSignature.isEmpty) {
      throw ArgumentError.value(
        failureSignature,
        'failureSignature',
        'Workshop build repair failure signature cannot be empty.',
      );
    }

    if (_buildRepairRootProjectId != normalizedRoot) {
      _buildRepairRootProjectId = normalizedRoot;
      _buildRepairAttempts = 0;
      _lastBuildRepairFailureSignature = null;
    }

    if (_lastBuildRepairFailureSignature == normalizedSignature) {
      return WorkshopBuildRepairReservation.repeatedFailure;
    }

    if (_buildRepairAttempts >= policy.maxBuildRepairAttempts) {
      return WorkshopBuildRepairReservation.budgetExhausted;
    }

    _buildRepairAttempts += 1;
    _lastBuildRepairFailureSignature = normalizedSignature;
    return WorkshopBuildRepairReservation.reserved;
  }

  void clearBuildRepairChain() {
    _ensureAvailable();
    _buildRepairRootProjectId = null;
    _lastBuildRepairFailureSignature = null;
    _buildRepairAttempts = 0;
  }

  Future<WorkshopTaskInferenceResult> _execute(
    WorkshopProductionTaskHandle handle,
    CancellationToken token, {
    required bool isOffline,
    required bool isRetry,
    required bool isRestartResume,
  }) async {
    // Journaling is observability/recovery infrastructure and must never delay
    // the actual production runner. Start both operations immediately, then
    // join the journal boundary before persisting any terminal/checkpoint state.
    // This also preserves the historical synchronous-start contract used by
    // cancellation and single-flight callers.
    final journalStart = _beginJournalAttempt(
      handle: handle,
      isOffline: isOffline,
      isRetry: isRetry,
      isRestartResume: isRestartResume,
    );

    try {
      final resultFuture = _runner.runPrepared(
        handle: handle,
        cancellationToken: token,
        isOffline: isOffline,
      );
      final result = await resultFuture;

      await journalStart;

      if (token.isCancelled) {
        await _persistJournalStatus(
          WorkshopExecutionStatus.cancelled,
          resumePhase: 'cancelled',
        );
        _setState(
          _state.copyWith(
            status: WorkshopProductionExecutionStatus.cancelled,
            finishedAt: DateTime.now().toUtc(),
            clearResult: true,
            clearError: true,
          ),
        );
      } else {
        await _persistInferenceCheckpoint(
          handle: handle,
          result: result,
        );
        _setState(
          _state.copyWith(
            status: WorkshopProductionExecutionStatus.succeeded,
            result: result,
            finishedAt: DateTime.now().toUtc(),
            clearError: true,
          ),
        );
      }

      return result;
    } catch (error) {
      // If inference fails before persistence has finished, still let the
      // attempt creation settle before recording the failure/cancellation.
      await journalStart;

      if (token.isCancelled) {
        await _persistJournalStatus(
          WorkshopExecutionStatus.cancelled,
          resumePhase: 'cancelled',
        );
        _setState(
          _state.copyWith(
            status: WorkshopProductionExecutionStatus.cancelled,
            finishedAt: DateTime.now().toUtc(),
            clearResult: true,
            clearError: true,
          ),
        );
      } else {
        await _persistJournalStatus(
          WorkshopExecutionStatus.failed,
          resumePhase: 'failed',
          metadata: <String, dynamic>{
            'failureType': error.runtimeType.toString(),
          },
        );
        _setState(
          _state.copyWith(
            status: WorkshopProductionExecutionStatus.failed,
            error: error,
            finishedAt: DateTime.now().toUtc(),
            clearResult: true,
          ),
        );
      }
      rethrow;
    } finally {
      _activeRun = null;
      _cancellationToken = null;
    }
  }

  Future<void> _beginJournalAttempt({
    required WorkshopProductionTaskHandle handle,
    required bool isOffline,
    required bool isRetry,
    required bool isRestartResume,
  }) async {
    final store = _executionStore;
    if (store == null) return;

    final resource =
        isOffline ? WorkshopTaskResource.local : WorkshopTaskResource.hybridAi;
    try {
      final current = _journalExecution;
      WorkshopExecution? supersededSnapshotExecution;
      WorkshopExecution execution;
      if (isRetry &&
          current != null &&
          current.projectId == handle.plan.id &&
          current.taskId == handle.taskId) {
        final previousStatus = current.status.name;
        final previousResumePhase = current.resumePhase;
        supersededSnapshotExecution = current;
        execution = await store.beginNextAttempt(
          execution: current,
          resource: resource,
        );

        final nextMetadata = Map<String, dynamic>.from(execution.metadata)
          ..remove('validatedProposalSnapshot');
        execution = execution.copyWith(metadata: nextMetadata);

        if (isRestartResume) {
          execution = execution.copyWith(
            metadata: <String, dynamic>{
              ...execution.metadata,
              'processRestartResume': true,
              'previousStatus': previousStatus,
              'previousResumePhase': previousResumePhase,
            },
          );
        }
      } else {
        execution = await store.create(
          projectId: handle.plan.id,
          taskId: handle.taskId,
          sessionId: 'production:${handle.plan.id}:${handle.taskId}',
          resource: resource,
          metadata: <String, dynamic>{
            'surface': 'workshop-production',
            'multiRole': true,
            'offline': isOffline,
          },
        );
      }

      execution = execution.copyWith(
        status: WorkshopExecutionStatus.running,
        resumePhase: 'inference',
      );
      await store.save(execution);
      _journalExecution = execution;
      if (isRestartResume) {
        _restartReplayPending = false;
      }
      _executionJournalError = null;

      if (supersededSnapshotExecution != null) {
        await _removeRecoverySnapshotForExecution(
          supersededSnapshotExecution,
        );
      }
    } catch (error) {
      // The journal is observability/recovery infrastructure. It must never
      // bypass or duplicate the guarded production lifecycle if persistence is
      // temporarily unavailable.
      _executionJournalError = error;
    }
  }

  Future<void> _persistInferenceCheckpoint({
    required WorkshopProductionTaskHandle handle,
    required WorkshopTaskInferenceResult result,
  }) async {
    final reviewApproved = result.review.approved;
    final validationValid = result.validation?.valid;
    final ready = result.readyForApproval;
    final recoveryMetadata = ready
        ? await _captureValidatedProposalSnapshot(
            handle: handle,
            result: result,
          )
        : const <String, dynamic>{};
    await _persistJournalStatus(
      ready
          ? WorkshopExecutionStatus.waitingApproval
          : WorkshopExecutionStatus.checkpointed,
      resumePhase: ready
          ? 'waitingApproval'
          : reviewApproved
              ? 'validation'
              : 'review',
      metadata: <String, dynamic>{
        'reviewApproved': reviewApproved,
        'validationValid': validationValid,
        'proposalChangeCount': result.proposal.changes.length,
        'stagedChangeCount': handle.session.workspace.changeCount,
        ...recoveryMetadata,
      },
    );
  }

  Future<Map<String, dynamic>> _captureValidatedProposalSnapshot({
    required WorkshopProductionTaskHandle handle,
    required WorkshopTaskInferenceResult result,
  }) async {
    final service = _validatedProposalSnapshotService;
    final execution = _journalExecution;
    if (service == null || execution == null || !result.readyForApproval) {
      return const <String, dynamic>{};
    }

    try {
      final snapshot = await service.capture(
        executionId: execution.executionId,
        attemptId: execution.attemptId,
        projectId: execution.projectId,
        taskId: execution.taskId,
        result: result,
        baselineSnapshot: handle.session.workspace.originalSnapshot,
        stagedSnapshot: handle.session.workspace.snapshot,
      );
      _recoverySnapshotError = null;
      return snapshot.toExecutionMetadata();
    } catch (error) {
      // Snapshot persistence augments recovery; it must never block a valid
      // approval-ready task. Restart falls back to P4.1 safe replay.
      _recoverySnapshotError = error;
      return const <String, dynamic>{};
    }
  }

  Future<void> _persistJournalStatus(
    WorkshopExecutionStatus status, {
    String? resumePhase,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    final store = _executionStore;
    final current = _journalExecution;
    if (store == null || current == null) return;

    try {
      final updated = current.copyWith(
        status: status,
        resumePhase: resumePhase,
        metadata: <String, dynamic>{
          ...current.metadata,
          ...metadata,
        },
      );
      await store.save(updated);
      _journalExecution = updated;
      _executionJournalError = null;
    } catch (error) {
      _executionJournalError = error;
    }
  }

  Future<void> _removeRecoverySnapshotForExecution(
    WorkshopExecution execution,
  ) async {
    final service = _validatedProposalSnapshotService;
    if (service == null ||
        execution.metadata['validatedProposalSnapshot'] == null) {
      return;
    }

    try {
      final snapshot =
          WorkshopValidatedProposalSnapshot.fromExecutionMetadata(
        execution.metadata,
      );
      if (snapshot.executionId != execution.executionId ||
          snapshot.attemptId != execution.attemptId ||
          snapshot.projectId != execution.projectId ||
          snapshot.taskId != execution.taskId) {
        throw const FormatException(
          'Validated proposal cleanup identity does not match the '
          'authoritative Workshop execution.',
        );
      }
      await service.remove(snapshot);
      _recoverySnapshotError = null;
    } catch (error) {
      // Cleanup can leave only an orphaned local recovery artifact. It must
      // never roll back a completed/cancelled execution or revive approval.
      _recoverySnapshotError = error;
    }
  }

  /// Marks the current logical Execution complete only after the real guarded
  /// apply has succeeded. This never applies workspace changes by itself.
  Future<void> markCurrentExecutionCompleted() async {
    _ensureAvailable();
    await _persistJournalStatus(
      WorkshopExecutionStatus.completed,
      resumePhase: 'completed',
    );
    final completed = _journalExecution;
    if (completed != null &&
        completed.status == WorkshopExecutionStatus.completed) {
      await _removeRecoverySnapshotForExecution(completed);
      _journalExecution = null;
      _restartReplayPending = false;
    }
  }

  /// Cancels a non-terminal logical Execution when the owner explicitly closes
  /// the project. Process death does not call this method: a running record is
  /// intentionally left resumable for P4 recovery.
  Future<void> abandonCurrentExecution() async {
    _ensureAvailable();
    final current = _journalExecution;
    if (current == null) return;

    final store = _executionStore;
    if (store == null || current.isTerminal) {
      _journalExecution = null;
      return;
    }

    final cancelled = current.copyWith(
      status: WorkshopExecutionStatus.cancelled,
      resumePhase: 'cancelled',
    );
    try {
      await store.save(cancelled);
      await _removeRecoverySnapshotForExecution(cancelled);
      _journalExecution = null;
      _restartReplayPending = false;
      _executionJournalError = null;
    } catch (error) {
      _executionJournalError = error;
      rethrow;
    }
  }

  void _registerPreparedTask(WorkshopProductionTaskHandle handle) {
    final planId = handle.plan.id.trim();
    final taskId = handle.taskId.trim();
    if (planId.isEmpty || taskId.isEmpty) {
      throw StateError(
        'Workshop production execution requires authoritative plan and task ids.',
      );
    }

    if (_activePlanId != planId) {
      _activePlanId = planId;
      _startedTaskIds.clear();
    }

    if (_startedTaskIds.contains(taskId)) {
      return;
    }

    if (_startedTaskIds.length >= policy.maxDistinctTasksPerProject) {
      throw StateError(
        'Workshop production task limit reached for project "$planId" '
        '(${policy.maxDistinctTasksPerProject}).',
      );
    }

    _startedTaskIds.add(taskId);
  }

  /// Clears terminal task state before the next task while preserving the
  /// explicitly selected offline/online mode for the same production chain.
  void resetForNextTask() {
    _ensureAvailable();
    if (_activeRun != null) {
      throw StateError(
        'Cannot reset Workshop production execution while a task is running.',
      );
    }
    _restartReplayPending = false;
    _setState(WorkshopProductionExecutionState(isOffline: _state.isOffline));
  }

  /// Full execution-state reset. This intentionally resets the execution mode
  /// but leaves the independently bounded build-repair chain untouched.
  void reset() {
    _ensureAvailable();
    if (_activeRun != null) {
      throw StateError(
        'Cannot reset Workshop production execution while a task is running.',
      );
    }
    _restartReplayPending = false;
    _setState(const WorkshopProductionExecutionState());
  }

  void _setState(WorkshopProductionExecutionState next) {
    if (_disposed) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  void _ensureAvailable() {
    if (_disposed) {
      throw StateError('WorkshopProductionExecutionController is disposed.');
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancellationToken?.cancel();
    _cancellationToken = null;
    _startedTaskIds.clear();
    _activePlanId = null;
    _buildRepairRootProjectId = null;
    _lastBuildRepairFailureSignature = null;
    _buildRepairAttempts = 0;
    _journalExecution = null;
    _executionJournalError = null;
    _recoverySnapshotError = null;
    _restartReplayPending = false;
    super.dispose();
  }
}
