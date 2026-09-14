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

final class WorkshopProductionExecutionState {
  const WorkshopProductionExecutionState({
    this.status = WorkshopProductionExecutionStatus.idle,
    this.handle,
    this.result,
    this.error,
    this.startedAt,
    this.finishedAt,
  });

  final WorkshopProductionExecutionStatus status;
  final WorkshopProductionTaskHandle? handle;
  final WorkshopTaskInferenceResult? result;
  final Object? error;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get isRunning =>
      status == WorkshopProductionExecutionStatus.running ||
      status == WorkshopProductionExecutionStatus.cancelling;

  bool get hasResult => result != null;

  WorkshopProductionExecutionState copyWith({
    WorkshopProductionExecutionStatus? status,
    WorkshopProductionTaskHandle? handle,
    WorkshopTaskInferenceResult? result,
    Object? error,
    DateTime? startedAt,
    DateTime? finishedAt,
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
  }) {
    return _coordinator.runPrepared(
      handle: handle,
      cancellationToken: cancellationToken,
    );
  }
}

/// Owns one long-running Cantiere task execution independently from widgets.
///
/// A page may attach/detach listeners without owning the task itself. The
/// controller never approves or applies changes: after inference succeeds, the
/// existing Reviewer/validation/owner approval/apply gates remain authoritative.
final class WorkshopProductionExecutionController extends ChangeNotifier {
  WorkshopProductionExecutionController({
    required WorkshopProductionExecutionRunner runner,
  }) : _runner = runner;

  final WorkshopProductionExecutionRunner _runner;

  WorkshopProductionExecutionState _state =
      const WorkshopProductionExecutionState();
  CancellationToken? _cancellationToken;
  Future<WorkshopTaskInferenceResult>? _activeRun;
  bool _disposed = false;

  WorkshopProductionExecutionState get state => _state;

  Future<WorkshopTaskInferenceResult> start() {
    _ensureAvailable();

    final activeRun = _activeRun;
    if (activeRun != null) {
      return activeRun;
    }

    final handle = _runner.preparedHandle();
    final token = CancellationToken();
    _cancellationToken = token;

    _setState(
      WorkshopProductionExecutionState(
        status: WorkshopProductionExecutionStatus.running,
        handle: handle,
        startedAt: DateTime.now().toUtc(),
      ),
    );

    final run = _execute(handle, token);
    _activeRun = run;
    return run;
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

  Future<WorkshopTaskInferenceResult> _execute(
    WorkshopProductionTaskHandle handle,
    CancellationToken token,
  ) async {
    try {
      final result = await _runner.runPrepared(
        handle: handle,
        cancellationToken: token,
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
    super.dispose();
  }
}
