import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
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
/// The controller also owns bounded execution budgets that must survive route
/// rebuilds: distinct tasks per project and build-repair attempts per logical
/// repair chain. It still owns no build logic and performs no workspace writes.
final class WorkshopProductionExecutionController extends ChangeNotifier {
  WorkshopProductionExecutionController({
    required WorkshopProductionExecutionRunner runner,
    this.policy = const WorkshopProductionExecutionPolicy(),
  }) : _runner = runner;

  final WorkshopProductionExecutionRunner _runner;
  final WorkshopProductionExecutionPolicy policy;

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

  WorkshopProductionExecutionState get state => _state;

  int get distinctTasksStartedInCurrentProject => _startedTaskIds.length;
  int get buildRepairAttempts => _buildRepairAttempts;
  String? get buildRepairRootProjectId => _buildRepairRootProjectId;
  String? get lastBuildRepairFailureSignature =>
      _lastBuildRepairFailureSignature;

  Future<WorkshopTaskInferenceResult> start({bool isOffline = false}) {
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

    final run = _execute(handle, token, isOffline: isOffline);
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
    return start(isOffline: isOffline);
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
  }) async {
    try {
      final result = await _runner.runPrepared(
        handle: handle,
        cancellationToken: token,
        isOffline: isOffline,
      );

      if (token.isCancelled) {
        _setState(
          _state.copyWith(
            status: WorkshopProductionExecutionStatus.cancelled,
            finishedAt: DateTime.now().toUtc(),
            clearResult: true,
            clearError: true,
          ),
        );
      } else {
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
      if (token.isCancelled) {
        _setState(
          _state.copyWith(
            status: WorkshopProductionExecutionStatus.cancelled,
            finishedAt: DateTime.now().toUtc(),
            clearResult: true,
            clearError: true,
          ),
        );
      } else {
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
    super.dispose();
  }
}
