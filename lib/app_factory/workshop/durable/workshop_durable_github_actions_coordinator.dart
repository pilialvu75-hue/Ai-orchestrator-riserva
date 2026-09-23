import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_github_build_monitor.dart';

enum WorkshopDurableGitHubDispatchDisposition {
  accepted,
  ambiguous,
  rejected,
}

final class WorkshopDurableGitHubDispatchOutcome {
  const WorkshopDurableGitHubDispatchOutcome({
    required this.disposition,
    this.failureClass,
    this.message,
  });

  final WorkshopDurableGitHubDispatchDisposition disposition;
  final WorkshopDurableFailureClass? failureClass;
  final String? message;

  static const accepted = WorkshopDurableGitHubDispatchOutcome(
    disposition: WorkshopDurableGitHubDispatchDisposition.accepted,
  );

  static const ambiguous = WorkshopDurableGitHubDispatchOutcome(
    disposition: WorkshopDurableGitHubDispatchDisposition.ambiguous,
  );
}

final class WorkshopDurableGitHubGatewayException implements Exception {
  const WorkshopDurableGitHubGatewayException(
    this.message, {
    this.failureClass = WorkshopDurableFailureClass.providerUnavailable,
    this.definitive = false,
  });

  final String message;
  final WorkshopDurableFailureClass failureClass;

  /// Definitive means the external side effect is known not to have happened.
  /// Non-definitive transport failures remain parked so reconciliation can
  /// discover a run that may have been accepted remotely.
  final bool definitive;

  @override
  String toString() => message;
}

/// One-shot GitHub Actions boundary.
///
/// Implementations may use GitHub REST, a webhook-backed cache or another
/// provider-specific transport. None of these methods may busy-wait.
abstract interface class WorkshopDurableGitHubActionsGateway {
  Future<WorkshopDurableGitHubDispatchOutcome> dispatch({
    required WorkshopBuildRequest request,
    required String correlationId,
  });

  Future<WorkshopGitHubRun?> discoverRun({
    required WorkshopBuildRequest request,
    required String correlationId,
  });

  Future<WorkshopGitHubRun?> getRun(int runId);

  Future<List<WorkshopGitHubArtifact>> getArtifacts(int runId);
}

enum WorkshopDurableGitHubReconcileDisposition {
  parkedForRunDiscovery,
  waitingForRunDiscovery,
  parkedForCompletion,
  waitingForCompletion,
  validating,
  retrying,
  failed,
  cancelled,
  unchanged,
}

final class WorkshopDurableGitHubReconcileResult {
  const WorkshopDurableGitHubReconcileResult({
    required this.snapshot,
    required this.disposition,
    this.runId,
  });

  final WorkshopDurableProjectSnapshot snapshot;
  final WorkshopDurableGitHubReconcileDisposition disposition;
  final int? runId;
}

/// Bridges GitHub Actions into the Durable Orchestrator without retaining a
/// polling Future.
///
/// The coordinator models the GitHub workflow as two external waits:
///
/// 1. dispatch correlation -> ci.started (run id discovered)
/// 2. run id -> ci.completed
///
/// Reconciliation is deliberately one-shot. A platform scheduler, webhook or
/// foreground recovery pass invokes [reconcile] again later.
final class WorkshopDurableGitHubActionsCoordinator {
  WorkshopDurableGitHubActionsCoordinator({
    required WorkshopDurableOrchestrator orchestrator,
    required WorkshopDurableGitHubActionsGateway gateway,
    DateTime Function()? clock,
    this.runDiscoveryTimeout = const Duration(minutes: 3),
    this.runCompletionTimeout = const Duration(minutes: 45),
  })  : _orchestrator = orchestrator,
        _gateway = gateway,
        _clock = clock ?? DateTime.now;

  final WorkshopDurableOrchestrator _orchestrator;
  final WorkshopDurableGitHubActionsGateway _gateway;
  final DateTime Function() _clock;
  final Duration runDiscoveryTimeout;
  final Duration runCompletionTimeout;

  Future<WorkshopDurableGitHubReconcileResult> dispatchAndPark({
    required String projectId,
    required String taskId,
    required String operationIdempotencyKey,
    required String dispatchCorrelationId,
    required WorkshopBuildRequest request,
  }) async {
    var snapshot = await _requiredProject(projectId);
    var task = _requiredTask(snapshot, taskId);

    if (task.state == WorkshopDurableState.waitingExternal) {
      final operationKey =
          _identity(operationIdempotencyKey, 'operationIdempotencyKey');
      if (!snapshot.claimedOperationKeys.contains(operationKey)) {
        throw StateError(
          'Existing GitHub wait belongs to a different durable operation.',
        );
      }
      final wait = task.externalWait;
      if (wait?.eventType == WorkshopDurableEventTypes.ciStarted &&
          wait?.externalId !=
              _identity(dispatchCorrelationId, 'dispatchCorrelationId')) {
        throw StateError(
          'Existing GitHub run-discovery wait has a different correlation id.',
        );
      }
      return WorkshopDurableGitHubReconcileResult(
        snapshot: snapshot,
        disposition: _waitingDisposition(wait),
        runId: _runId(wait),
      );
    }

    if (task.state != WorkshopDurableState.ready &&
        task.state != WorkshopDurableState.retrying) {
      throw StateError(
        'GitHub durable dispatch requires READY/RETRYING task, got ' +
            task.state.name,
      );
    }

    final now = _clock().toUtc();
    snapshot = await _orchestrator.startTaskAndWaitForExternal(
      projectId: projectId,
      taskId: taskId,
      operationIdempotencyKey: operationIdempotencyKey,
      wait: WorkshopDurableExternalWait(
        eventType: WorkshopDurableEventTypes.ciStarted,
        externalId: _identity(
          dispatchCorrelationId,
          'dispatchCorrelationId',
        ),
        startedAt: now,
        timeoutAt: now.add(runDiscoveryTimeout),
        successState: WorkshopDurableState.running,
      ),
      startReason: WorkshopDurableEventTypes.taskStarted,
      waitReason: 'github.dispatch.persisted_before_side_effect',
    );

    try {
      final outcome = await _gateway.dispatch(
        request: request,
        correlationId: dispatchCorrelationId,
      );

      if (outcome.disposition ==
          WorkshopDurableGitHubDispatchDisposition.rejected) {
        final failed = await _orchestrator.failTask(
          projectId: projectId,
          taskId: taskId,
          failureClass: outcome.failureClass ??
              WorkshopDurableFailureClass.providerUnavailable,
          reason: 'github.dispatch.rejected',
        );
        return _stateResult(failed);
      }

      // accepted and ambiguous both remain parked. An ambiguous network result
      // may still have been accepted by GitHub; redispatching immediately would
      // risk duplicate CI/spend.
      return WorkshopDurableGitHubReconcileResult(
        snapshot: snapshot,
        disposition:
            WorkshopDurableGitHubReconcileDisposition.parkedForRunDiscovery,
      );
    } on WorkshopDurableGitHubGatewayException catch (error) {
      if (!error.definitive) {
        return WorkshopDurableGitHubReconcileResult(
          snapshot: snapshot,
          disposition:
              WorkshopDurableGitHubReconcileDisposition.parkedForRunDiscovery,
        );
      }
      final failed = await _orchestrator.failTask(
        projectId: projectId,
        taskId: taskId,
        failureClass: error.failureClass,
        reason: 'github.dispatch.definitive_failure',
      );
      return _stateResult(failed);
    } catch (_) {
      // Unknown transport exceptions are treated as ambiguous. The durable
      // correlation is already persisted, so later discovery gets the first
      // chance to prove whether a workflow exists.
      return WorkshopDurableGitHubReconcileResult(
        snapshot: snapshot,
        disposition:
            WorkshopDurableGitHubReconcileDisposition.parkedForRunDiscovery,
      );
    }
  }

  Future<WorkshopDurableGitHubReconcileResult> reconcile({
    required String projectId,
    required String taskId,
    required WorkshopBuildRequest request,
  }) async {
    final snapshot = await _requiredProject(projectId);
    final task = _requiredTask(snapshot, taskId);
    final wait = task.externalWait;

    if (task.state != WorkshopDurableState.waitingExternal || wait == null) {
      return WorkshopDurableGitHubReconcileResult(
        snapshot: snapshot,
        disposition: WorkshopDurableGitHubReconcileDisposition.unchanged,
      );
    }

    if (wait.eventType == WorkshopDurableEventTypes.ciStarted) {
      return _reconcileRunDiscovery(
        snapshot: snapshot,
        task: task,
        wait: wait,
        request: request,
      );
    }

    if (wait.eventType == WorkshopDurableEventTypes.ciCompleted) {
      return _reconcileCompletion(
        snapshot: snapshot,
        task: task,
        wait: wait,
      );
    }

    return WorkshopDurableGitHubReconcileResult(
      snapshot: snapshot,
      disposition: WorkshopDurableGitHubReconcileDisposition.unchanged,
    );
  }

  Future<WorkshopDurableGitHubReconcileResult> _reconcileRunDiscovery({
    required WorkshopDurableProjectSnapshot snapshot,
    required WorkshopDurableTask task,
    required WorkshopDurableExternalWait wait,
    required WorkshopBuildRequest request,
  }) async {
    final correlation = wait.externalId;
    if (correlation == null || correlation.trim().isEmpty) {
      throw StateError('GitHub run-discovery wait is missing correlation id.');
    }

    WorkshopGitHubRun? run;
    try {
      run = await _gateway.discoverRun(
        request: request,
        correlationId: correlation,
      );
    } on WorkshopDurableGitHubGatewayException catch (error) {
      if (error.definitive) {
        final failed = await _orchestrator.failTask(
          projectId: snapshot.projectId,
          taskId: task.taskId,
          failureClass: error.failureClass,
          reason: 'github.run_discovery.failed',
        );
        return _stateResult(failed);
      }
    } catch (_) {
      // One failed observation does not convert an external wait into a task
      // failure. Timeout policy below remains authoritative.
    }

    if (run == null) {
      return _waitingOrTimeout(
        snapshot: snapshot,
        task: task,
        wait: wait,
        waiting:
            WorkshopDurableGitHubReconcileDisposition.waitingForRunDiscovery,
      );
    }

    final now = _clock().toUtc();
    final event = WorkshopDurableExternalEvent(
      type: WorkshopDurableEventTypes.ciStarted,
      projectId: snapshot.projectId,
      taskId: task.taskId,
      correlationId: snapshot.correlationId,
      idempotencyKey: _startedEventKey(snapshot, task, run.id),
      occurredAt: (run.createdAt ?? now).toUtc(),
      success: true,
      externalId: correlation,
    );

    final handled = await _orchestrator.handleExternalEvent(
      event,
      nextWait: WorkshopDurableExternalWait(
        eventType: WorkshopDurableEventTypes.ciCompleted,
        externalId: run.id.toString(),
        startedAt: now,
        timeoutAt: now.add(runCompletionTimeout),
        successState: WorkshopDurableState.validating,
      ),
    );

    return WorkshopDurableGitHubReconcileResult(
      snapshot: handled.snapshot,
      disposition:
          WorkshopDurableGitHubReconcileDisposition.parkedForCompletion,
      runId: run.id,
    );
  }

  Future<WorkshopDurableGitHubReconcileResult> _reconcileCompletion({
    required WorkshopDurableProjectSnapshot snapshot,
    required WorkshopDurableTask task,
    required WorkshopDurableExternalWait wait,
  }) async {
    final runId = int.tryParse(wait.externalId ?? '');
    if (runId == null || runId <= 0) {
      throw StateError('GitHub completion wait contains an invalid run id.');
    }

    WorkshopGitHubRun? run;
    try {
      run = await _gateway.getRun(runId);
    } on WorkshopDurableGitHubGatewayException catch (error) {
      if (error.definitive) {
        final failed = await _orchestrator.failTask(
          projectId: snapshot.projectId,
          taskId: task.taskId,
          failureClass: error.failureClass,
          reason: 'github.run_observation.failed',
        );
        return _stateResult(failed, runId: runId);
      }
    } catch (_) {
      // Same rule as discovery: an observation failure is not proof that the
      // remote workflow failed.
    }

    if (run == null || !run.isCompleted) {
      return _waitingOrTimeout(
        snapshot: snapshot,
        task: task,
        wait: wait,
        waiting:
            WorkshopDurableGitHubReconcileDisposition.waitingForCompletion,
        runId: runId,
      );
    }

    final artifactIds = <String>[];
    if (run.succeeded) {
      try {
        final artifacts = await _gateway.getArtifacts(runId);
        for (final artifact in artifacts) {
          if (!artifact.isDownloadable) continue;
          artifactIds.add(
            'github-artifact:' +
                artifact.id.toString() +
                ':' +
                artifact.name,
          );
        }
        artifactIds.sort();
      } on WorkshopDurableGitHubGatewayException catch (error) {
        if (error.definitive) {
          final failed = await _orchestrator.failTask(
            projectId: snapshot.projectId,
            taskId: task.taskId,
            failureClass: error.failureClass,
            reason: 'github.artifact_observation.failed',
          );
          return _stateResult(failed, runId: runId);
        }
        return _waitingOrTimeout(
          snapshot: snapshot,
          task: task,
          wait: wait,
          waiting:
              WorkshopDurableGitHubReconcileDisposition.waitingForCompletion,
          runId: runId,
        );
      } catch (_) {
        return _waitingOrTimeout(
          snapshot: snapshot,
          task: task,
          wait: wait,
          waiting:
              WorkshopDurableGitHubReconcileDisposition.waitingForCompletion,
          runId: runId,
        );
      }
    }

    final handled = await _orchestrator.handleExternalEvent(
      WorkshopDurableExternalEvent(
        type: WorkshopDurableEventTypes.ciCompleted,
        projectId: snapshot.projectId,
        taskId: task.taskId,
        correlationId: snapshot.correlationId,
        idempotencyKey: _completedEventKey(snapshot, task, run),
        occurredAt: (run.updatedAt ?? _clock()).toUtc(),
        success: run.succeeded,
        externalId: runId.toString(),
        failureClass: run.succeeded ? null : _failureClass(run),
        artifactIds: artifactIds,
      ),
    );

    return _stateResult(handled.snapshot, runId: runId);
  }

  Future<WorkshopDurableGitHubReconcileResult> _waitingOrTimeout({
    required WorkshopDurableProjectSnapshot snapshot,
    required WorkshopDurableTask task,
    required WorkshopDurableExternalWait wait,
    required WorkshopDurableGitHubReconcileDisposition waiting,
    int? runId,
  }) async {
    final timeoutAt = wait.timeoutAt;
    if (timeoutAt == null || !_clock().toUtc().isAfter(timeoutAt.toUtc())) {
      return WorkshopDurableGitHubReconcileResult(
        snapshot: snapshot,
        disposition: waiting,
        runId: runId,
      );
    }

    final failed = await _orchestrator.failTask(
      projectId: snapshot.projectId,
      taskId: task.taskId,
      failureClass: WorkshopDurableFailureClass.timeout,
      reason: 'github.external_wait_timeout',
    );
    return _stateResult(failed, runId: runId);
  }

  Future<WorkshopDurableProjectSnapshot> _requiredProject(
    String projectId,
  ) async {
    final snapshot = await _orchestrator.loadProject(projectId);
    if (snapshot == null) {
      throw StateError('Unknown durable project: ' + projectId);
    }
    return snapshot;
  }

  static WorkshopDurableTask _requiredTask(
    WorkshopDurableProjectSnapshot snapshot,
    String taskId,
  ) {
    final task = snapshot.tasks[taskId];
    if (task == null) {
      throw StateError('Unknown durable task: ' + taskId);
    }
    return task;
  }

  static WorkshopDurableGitHubReconcileDisposition _waitingDisposition(
    WorkshopDurableExternalWait? wait,
  ) {
    if (wait?.eventType == WorkshopDurableEventTypes.ciCompleted) {
      return WorkshopDurableGitHubReconcileDisposition.waitingForCompletion;
    }
    return WorkshopDurableGitHubReconcileDisposition.waitingForRunDiscovery;
  }

  static int? _runId(WorkshopDurableExternalWait? wait) {
    if (wait?.eventType != WorkshopDurableEventTypes.ciCompleted) return null;
    return int.tryParse(wait?.externalId ?? '');
  }

  static WorkshopDurableGitHubReconcileResult _stateResult(
    WorkshopDurableProjectSnapshot snapshot, {
    int? runId,
  }) {
    final disposition = switch (snapshot.state) {
      WorkshopDurableState.validating =>
        WorkshopDurableGitHubReconcileDisposition.validating,
      WorkshopDurableState.retrying =>
        WorkshopDurableGitHubReconcileDisposition.retrying,
      WorkshopDurableState.failed =>
        WorkshopDurableGitHubReconcileDisposition.failed,
      WorkshopDurableState.cancelled =>
        WorkshopDurableGitHubReconcileDisposition.cancelled,
      _ => WorkshopDurableGitHubReconcileDisposition.unchanged,
    };
    return WorkshopDurableGitHubReconcileResult(
      snapshot: snapshot,
      disposition: disposition,
      runId: runId,
    );
  }

  static WorkshopDurableFailureClass _failureClass(
    WorkshopGitHubRun run,
  ) {
    switch (run.conclusion) {
      case WorkshopGitHubRunConclusion.timedOut:
        return WorkshopDurableFailureClass.timeout;
      case WorkshopGitHubRunConclusion.actionRequired:
        return WorkshopDurableFailureClass.policyBlocked;
      case WorkshopGitHubRunConclusion.failure:
      case WorkshopGitHubRunConclusion.neutral:
      case WorkshopGitHubRunConclusion.skipped:
        return WorkshopDurableFailureClass.buildError;
      case WorkshopGitHubRunConclusion.cancelled:
      case WorkshopGitHubRunConclusion.unknown:
      case WorkshopGitHubRunConclusion.success:
        return WorkshopDurableFailureClass.unknown;
    }
  }

  static String _startedEventKey(
    WorkshopDurableProjectSnapshot snapshot,
    WorkshopDurableTask task,
    int runId,
  ) {
    return 'github:' +
        snapshot.projectId +
        ':' +
        task.taskId +
        ':run:' +
        runId.toString() +
        ':started';
  }

  static String _completedEventKey(
    WorkshopDurableProjectSnapshot snapshot,
    WorkshopDurableTask task,
    WorkshopGitHubRun run,
  ) {
    return 'github:' +
        snapshot.projectId +
        ':' +
        task.taskId +
        ':run:' +
        run.id.toString() +
        ':completed:' +
        run.conclusion.name;
  }

  static String _identity(String value, String field) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, field, 'must not be empty');
    }
    return normalized;
  }
}
