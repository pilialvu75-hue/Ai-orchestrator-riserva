import 'dart:io';

import '../workshop_build_lab.dart';
import 'workshop_durable_github_actions_coordinator.dart';
import 'workshop_durable_orchestrator.dart';

typedef WorkshopDurableArtifactExists = Future<bool> Function(String path);

typedef WorkshopDurableArtifactFinalize = Future<WorkshopBuildResult> Function({
  required WorkshopBuildRequest request,
  required String correlationId,
  required int runId,
});

enum WorkshopDurableFinalBuildDisposition {
  dispatched,
  waitingForRun,
  waitingForCompletion,
  finalizing,
  retrying,
  completed,
  failed,
  cancelled,
}

final class WorkshopDurableFinalBuildAdvance {
  const WorkshopDurableFinalBuildAdvance({
    required this.snapshot,
    required this.disposition,
    this.buildResult,
    this.message,
  });

  final WorkshopDurableProjectSnapshot snapshot;
  final WorkshopDurableFinalBuildDisposition disposition;
  final WorkshopBuildResult? buildResult;
  final String? message;

  bool get isTerminal =>
      disposition == WorkshopDurableFinalBuildDisposition.completed ||
      disposition == WorkshopDurableFinalBuildDisposition.failed ||
      disposition == WorkshopDurableFinalBuildDisposition.cancelled;
}

/// One-step durable controller for the final Cantiere build.
///
/// This class intentionally does not retain a polling Future or own a timer.
/// Each [advance] call performs at most one external reconciliation step. The
/// durable orchestrator persists the authoritative external wait/run state, so
/// a fresh controller instance can continue after process death.
final class WorkshopDurableFinalBuildController {
  WorkshopDurableFinalBuildController({
    required WorkshopDurableOrchestrator orchestrator,
    required WorkshopDurableGitHubActionsCoordinator githubCoordinator,
    required WorkshopDurableArtifactFinalize finalizeArtifact,
    required String logicalBuildId,
    WorkshopDurableArtifactExists? artifactExists,
    DateTime Function()? clock,
  })  : _logicalBuildId = _verifiedBuildId(logicalBuildId),
        _orchestrator = orchestrator,
        _githubCoordinator = githubCoordinator,
        _finalizeArtifact = finalizeArtifact,
        _artifactExists = artifactExists ?? _localArtifactExists,
        _clock = clock ?? DateTime.now;

  static const String _taskId = 'final-build';

  final String _logicalBuildId;
  final WorkshopDurableOrchestrator _orchestrator;
  final WorkshopDurableGitHubActionsCoordinator _githubCoordinator;
  final WorkshopDurableArtifactFinalize _finalizeArtifact;
  final WorkshopDurableArtifactExists _artifactExists;
  final DateTime Function() _clock;

  /// Advances the final build exactly one durable step.
  ///
  /// A scheduler must persist the selected v2 source-bound identity and
  /// immutable source snapshot BEFORE dispatch, then supply that same identity
  /// across process restarts. To begin a new user-requested build (even from
  /// the same source after a terminal failure), allocate a NEW persisted
  /// generation and a different identity. UI request ids never become durable
  /// correlation identifiers. This controller is not production-wired.
  Future<WorkshopDurableFinalBuildAdvance> advance(
    WorkshopBuildRequest request,
  ) async {
    final logicalId = _logicalBuildId;
    final projectId = 'durable-final-build:$logicalId';

    var snapshot = await _orchestrator.loadProject(projectId);
    if (snapshot == null) {
      final now = _clock().toUtc();
      snapshot = await _orchestrator.createProject(
        projectId: projectId,
        correlationId: logicalId,
        tasks: <WorkshopDurableTask>[
          WorkshopDurableTask(
            taskId: _taskId,
            capability: 'build.${request.target.name}',
            state: WorkshopDurableState.created,
            updatedAt: now,
            retryPolicy: const WorkshopDurableRetryPolicy(
              maxAttempts: 3,
              retryableFailures: <WorkshopDurableFailureClass>{
                WorkshopDurableFailureClass.networkError,
                WorkshopDurableFailureClass.rateLimit,
                WorkshopDurableFailureClass.providerUnavailable,
                WorkshopDurableFailureClass.timeout,
              },
            ),
            timeout: const Duration(minutes: 45),
            completionCriterionIds: const <String>[
              'artifact.provenance_verified',
              'artifact.hash_verified',
              'artifact.validation_verified',
            ],
          ),
        ],
      );
      snapshot = await _orchestrator.markProjectReady(projectId);
    }

    final task = _requiredTask(snapshot);
    switch (task.state) {
      case WorkshopDurableState.created:
      case WorkshopDurableState.planning:
        snapshot = await _orchestrator.markProjectReady(projectId);
        return _dispatchReady(request, snapshot, logicalId);
      case WorkshopDurableState.ready:
        return _dispatchReady(request, snapshot, logicalId);
      case WorkshopDurableState.retrying:
        final retryNotBefore = task.retryNotBefore;
        if (retryNotBefore != null &&
            _clock().toUtc().isBefore(retryNotBefore.toUtc())) {
          return WorkshopDurableFinalBuildAdvance(
            snapshot: snapshot,
            disposition: WorkshopDurableFinalBuildDisposition.retrying,
            message: 'Durable final build retry is not due yet.',
          );
        }
        return _dispatchReady(request, snapshot, logicalId);
      case WorkshopDurableState.waitingExternal:
        final reconciled = await _githubCoordinator.reconcile(
          projectId: projectId,
          taskId: _taskId,
          request: request,
        );
        // Reconciliation is one external step. A persisted VALIDATING
        // checkpoint starts artifact download only on the next invocation.
        return _fromReconcile(reconciled, request);
      case WorkshopDurableState.validating:
        return _finalize(
          request: request,
          snapshot: snapshot,
          logicalId: logicalId,
          runId: _completedRunId(snapshot),
        );
      case WorkshopDurableState.completed:
        return _completed(request, snapshot);
      case WorkshopDurableState.failed:
        return _terminalFailure(
          request,
          snapshot,
          WorkshopBuildStatus.failed,
          'Durable final build failed.',
          'durable_final_build_failed',
        );
      case WorkshopDurableState.cancelled:
        return _terminalFailure(
          request,
          snapshot,
          WorkshopBuildStatus.cancelled,
          'Durable final build was cancelled.',
          'durable_final_build_cancelled',
        );
      case WorkshopDurableState.running:
      case WorkshopDurableState.blocked:
        return WorkshopDurableFinalBuildAdvance(
          snapshot: snapshot,
          disposition: task.state == WorkshopDurableState.blocked
              ? WorkshopDurableFinalBuildDisposition.failed
              : WorkshopDurableFinalBuildDisposition.retrying,
          message: 'Durable final build is in ${task.state.name}.',
        );
    }
  }

  Future<WorkshopDurableFinalBuildAdvance> _dispatchReady(
    WorkshopBuildRequest request,
    WorkshopDurableProjectSnapshot snapshot,
    String logicalId,
  ) async {
    final task = _requiredTask(snapshot);
    final attempt = task.attemptsStarted + 1;
    final attemptCorrelation = _attemptCorrelation(logicalId, attempt);
    final result = await _githubCoordinator.dispatchAndPark(
      projectId: snapshot.projectId,
      taskId: _taskId,
      operationIdempotencyKey: 'github-dispatch:$attemptCorrelation',
      dispatchCorrelationId: attemptCorrelation,
      request: request,
    );

    switch (result.disposition) {
      case WorkshopDurableGitHubReconcileDisposition.parkedForRunDiscovery:
      case WorkshopDurableGitHubReconcileDisposition.waitingForRunDiscovery:
        return WorkshopDurableFinalBuildAdvance(
          snapshot: result.snapshot,
          disposition: WorkshopDurableFinalBuildDisposition.dispatched,
          message: 'Durable GitHub build dispatched and parked.',
        );
      case WorkshopDurableGitHubReconcileDisposition.retrying:
        return WorkshopDurableFinalBuildAdvance(
          snapshot: result.snapshot,
          disposition: WorkshopDurableFinalBuildDisposition.retrying,
        );
      case WorkshopDurableGitHubReconcileDisposition.failed:
        return _terminalFailure(
          request,
          result.snapshot,
          WorkshopBuildStatus.failed,
          'Durable GitHub dispatch failed.',
          'durable_dispatch_failed',
        );
      case WorkshopDurableGitHubReconcileDisposition.cancelled:
        return _terminalFailure(
          request,
          result.snapshot,
          WorkshopBuildStatus.cancelled,
          'Durable GitHub dispatch was cancelled.',
          'durable_dispatch_cancelled',
        );
      case WorkshopDurableGitHubReconcileDisposition.parkedForCompletion:
      case WorkshopDurableGitHubReconcileDisposition.waitingForCompletion:
      case WorkshopDurableGitHubReconcileDisposition.validating:
      case WorkshopDurableGitHubReconcileDisposition.unchanged:
        return _fromReconcile(result, request);
    }
  }

  WorkshopDurableFinalBuildAdvance _fromReconcile(
    WorkshopDurableGitHubReconcileResult result,
    WorkshopBuildRequest request,
  ) {
    switch (result.disposition) {
      case WorkshopDurableGitHubReconcileDisposition.parkedForRunDiscovery:
      case WorkshopDurableGitHubReconcileDisposition.waitingForRunDiscovery:
        return WorkshopDurableFinalBuildAdvance(
          snapshot: result.snapshot,
          disposition: WorkshopDurableFinalBuildDisposition.waitingForRun,
        );
      case WorkshopDurableGitHubReconcileDisposition.parkedForCompletion:
      case WorkshopDurableGitHubReconcileDisposition.waitingForCompletion:
        return WorkshopDurableFinalBuildAdvance(
          snapshot: result.snapshot,
          disposition:
              WorkshopDurableFinalBuildDisposition.waitingForCompletion,
        );
      case WorkshopDurableGitHubReconcileDisposition.validating:
        return WorkshopDurableFinalBuildAdvance(
          snapshot: result.snapshot,
          disposition: WorkshopDurableFinalBuildDisposition.finalizing,
        );
      case WorkshopDurableGitHubReconcileDisposition.retrying:
        return WorkshopDurableFinalBuildAdvance(
          snapshot: result.snapshot,
          disposition: WorkshopDurableFinalBuildDisposition.retrying,
        );
      case WorkshopDurableGitHubReconcileDisposition.failed:
        return _terminalFailure(
          request,
          result.snapshot,
          WorkshopBuildStatus.failed,
          'Durable GitHub build failed.',
          'durable_remote_build_failed',
        );
      case WorkshopDurableGitHubReconcileDisposition.cancelled:
        return _terminalFailure(
          request,
          result.snapshot,
          WorkshopBuildStatus.cancelled,
          'Durable GitHub build was cancelled.',
          'durable_remote_build_cancelled',
        );
      case WorkshopDurableGitHubReconcileDisposition.unchanged:
        return WorkshopDurableFinalBuildAdvance(
          snapshot: result.snapshot,
          disposition: WorkshopDurableFinalBuildDisposition.finalizing,
        );
    }
  }

  Future<WorkshopDurableFinalBuildAdvance> _finalize({
    required WorkshopBuildRequest request,
    required WorkshopDurableProjectSnapshot snapshot,
    required String logicalId,
    required int? runId,
  }) async {
    final task = _requiredTask(snapshot);
    final resolvedRunId = runId ?? _completedRunId(snapshot);
    if (resolvedRunId == null) {
      return WorkshopDurableFinalBuildAdvance(
        snapshot: snapshot,
        disposition: WorkshopDurableFinalBuildDisposition.finalizing,
        message: 'Completed GitHub run id is not available yet.',
      );
    }
    if (task.attemptsStarted <= 0) {
      throw StateError('Durable final build has no started attempt to finalize.');
    }

    final attemptCorrelation =
        _attemptCorrelation(logicalId, task.attemptsStarted);
    try {
      final buildResult = await _finalizeArtifact(
        request: request,
        correlationId: attemptCorrelation,
        runId: resolvedRunId,
      );
      final artifactPath = buildResult.artifactPath?.trim();
      if (!buildResult.succeeded ||
          artifactPath == null ||
          artifactPath.isEmpty ||
          buildResult.testsPassed != true ||
          buildResult.analysisPassed != true ||
          buildResult.formatPassed != true) {
        throw const WorkshopDurableGitHubGatewayException(
          'Durable artifact finalizer did not return a fully verified APK.',
          failureClass: WorkshopDurableFailureClass.validationFailed,
          definitive: true,
        );
      }
      final completed = await _orchestrator.validationPassed(
        projectId: snapshot.projectId,
        taskId: _taskId,
        artifactIds: <String>['local-apk:$artifactPath'],
      );
      return WorkshopDurableFinalBuildAdvance(
        snapshot: completed,
        disposition: WorkshopDurableFinalBuildDisposition.completed,
        buildResult: buildResult,
      );
    } on WorkshopDurableGitHubGatewayException catch (error) {
      if (!error.definitive) {
        return WorkshopDurableFinalBuildAdvance(
          snapshot: snapshot,
          disposition: WorkshopDurableFinalBuildDisposition.finalizing,
          message: error.message,
        );
      }
      final failed = await _orchestrator.failTask(
        projectId: snapshot.projectId,
        taskId: _taskId,
        failureClass: error.failureClass,
        reason: WorkshopDurableEventTypes.validationFailed,
      );
      final failedTask = _requiredTask(failed);
      if (failedTask.state == WorkshopDurableState.retrying) {
        return WorkshopDurableFinalBuildAdvance(
          snapshot: failed,
          disposition: WorkshopDurableFinalBuildDisposition.retrying,
          message: error.message,
        );
      }
      return _terminalFailure(
        request,
        failed,
        WorkshopBuildStatus.failed,
        error.message,
        'durable_artifact_validation_failed',
      );
    }
  }

  Future<WorkshopDurableFinalBuildAdvance> _completed(
    WorkshopBuildRequest request,
    WorkshopDurableProjectSnapshot snapshot,
  ) async {
    final path = _localArtifactPath(_requiredTask(snapshot));
    // A persisted COMPLETED state alone cannot prove that its APK still
    // exists. Never return a stale success after local storage cleanup.
    if (path == null || !(await _artifactExists(path))) {
      return _terminalFailure(
        request,
        snapshot,
        WorkshopBuildStatus.failed,
        'Previously verified durable APK is no longer available locally.',
        'durable_materialized_apk_missing',
      );
    }
    final result = WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.succeeded,
      startedAt: snapshot.createdAt,
      finishedAt: snapshot.updatedAt,
      artifactPath: path,
      message: 'Durable Android APK is already verified.',
      exitCode: 0,
      testsPassed: true,
      analysisPassed: true,
      formatPassed: true,
    );
    return WorkshopDurableFinalBuildAdvance(
      snapshot: snapshot,
      disposition: WorkshopDurableFinalBuildDisposition.completed,
      buildResult: result,
    );
  }

  WorkshopDurableFinalBuildAdvance _terminalFailure(
    WorkshopBuildRequest request,
    WorkshopDurableProjectSnapshot snapshot,
    WorkshopBuildStatus status,
    String message,
    String errorCode,
  ) {
    final result = WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: status,
      startedAt: snapshot.createdAt,
      finishedAt: snapshot.updatedAt,
      message: message,
      errors: status == WorkshopBuildStatus.failed
          ? <String>[errorCode]
          : const <String>[],
    );
    return WorkshopDurableFinalBuildAdvance(
      snapshot: snapshot,
      disposition: status == WorkshopBuildStatus.cancelled
          ? WorkshopDurableFinalBuildDisposition.cancelled
          : WorkshopDurableFinalBuildDisposition.failed,
      buildResult: result,
      message: message,
    );
  }

  static WorkshopDurableTask _requiredTask(
    WorkshopDurableProjectSnapshot snapshot,
  ) {
    final task = snapshot.tasks[_taskId];
    if (task == null) {
      throw StateError('Durable final build task is missing.');
    }
    return task;
  }

  static int? _completedRunId(WorkshopDurableProjectSnapshot snapshot) {
    final task = _requiredTask(snapshot);
    if (task.attemptsStarted <= 0) return null;

    // Events that fail to match the active wait are still RECEIVED in the
    // durable journal. Only processed successful completions are trustworthy.
    // Moreover, bind the run ID to the START event for the current attempt,
    // never an accepted completion belonging to an earlier retry.
    final currentCorrelation =
        _attemptCorrelation(snapshot.correlationId, task.attemptsStarted);
    final runPrefix = 'github:${snapshot.projectId}:$_taskId:run:';
    final currentAttemptRunIds = <int>{};
    for (final event in snapshot.events) {
      if (event.taskId != _taskId ||
          event.type != WorkshopDurableEventTypes.ciStarted ||
          !event.success ||
          event.externalId != currentCorrelation ||
          !snapshot.processedIdempotencyKeys.contains(event.idempotencyKey) ||
          !event.idempotencyKey.startsWith(runPrefix) ||
          !event.idempotencyKey.endsWith(':started')) {
        continue;
      }
      final runId = int.tryParse(event.idempotencyKey.substring(
        runPrefix.length,
        event.idempotencyKey.length - ':started'.length,
      ));
      if (runId != null && runId > 0) currentAttemptRunIds.add(runId);
    }

    for (final event in snapshot.events.reversed) {
      if (event.taskId != _taskId ||
          event.type != WorkshopDurableEventTypes.ciCompleted ||
          !event.success ||
          !snapshot.processedIdempotencyKeys.contains(event.idempotencyKey)) {
        continue;
      }
      final runId = int.tryParse(event.externalId ?? '');
      if (runId != null && currentAttemptRunIds.contains(runId)) {
        return runId;
      }
    }
    return null;
  }

  static String? _localArtifactPath(WorkshopDurableTask task) {
    for (final artifact in task.artifactIds.reversed) {
      if (artifact.startsWith('local-apk:')) {
        final path = artifact.substring('local-apk:'.length).trim();
        if (path.isNotEmpty) return path;
      }
    }
    return null;
  }

  static String _attemptCorrelation(String logicalId, int attempt) =>
      '$logicalId:attempt:$attempt';

  static String _verifiedBuildId(String value) {
    final trimmed = value.trim();
    if (!RegExp(r'^durable-v2-[a-f0-9]{40}$').hasMatch(trimmed)) {
      throw ArgumentError.value(
        value,
        'logicalBuildId',
        'Expected a source-bound identity with a persisted generation.',
      );
    }
    return trimmed;
  }

  static Future<bool> _localArtifactExists(String path) async {
    try {
      final file = File(path);
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }
}
