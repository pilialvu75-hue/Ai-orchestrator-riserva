import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_final_build_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_durable_github_build_provider.dart';

void main() {
  test('drives one-shot durable advances until verified terminal result',
      () async {
    var calls = 0;
    var delays = 0;
    final request = _request('ui-build');
    final success = _success(request);
    final provider = WorkshopDurableGitHubBuildProvider(
      advance: (request) async {
        calls += 1;
        if (calls == 1) {
          return _advance(
            WorkshopDurableFinalBuildDisposition.dispatched,
          );
        }
        if (calls == 2) {
          return _advance(
            WorkshopDurableFinalBuildDisposition.waitingForCompletion,
          );
        }
        return _advance(
          WorkshopDurableFinalBuildDisposition.completed,
          buildResult: success,
        );
      },
      toolchainDelegate: _ToolchainProvider(),
      delay: (_) async => delays += 1,
      pollInterval: const Duration(milliseconds: 1),
    );

    final result = await provider.build(request);

    expect(result, same(success));
    expect(calls, 3);
    expect(delays, 2);
  });

  test('foreground cancellation does not require mutating durable state',
      () async {
    final delayStarted = Completer<void>();
    final releaseDelay = Completer<void>();
    var calls = 0;
    final request = _request('cancel-me');
    final provider = WorkshopDurableGitHubBuildProvider(
      advance: (request) async {
        calls += 1;
        return _advance(
          WorkshopDurableFinalBuildDisposition.waitingForCompletion,
        );
      },
      toolchainDelegate: _ToolchainProvider(),
      delay: (_) async {
        if (!delayStarted.isCompleted) delayStarted.complete();
        await releaseDelay.future;
      },
      pollInterval: const Duration(milliseconds: 1),
    );

    final future = provider.build(request);
    await delayStarted.future;
    await provider.cancel(request.id);
    releaseDelay.complete();

    final result = await future;
    expect(result.status, WorkshopBuildStatus.cancelled);
    expect(result.requestId, request.id);
    expect(calls, 1);
  });

  test('cancellation during in-flight terminal advance wins over success',
      () async {
    final pending = Completer<WorkshopDurableFinalBuildAdvance>();
    final request = _request('cancel-during-terminal');
    final provider = WorkshopDurableGitHubBuildProvider(
      advance: (request) => pending.future,
      toolchainDelegate: _ToolchainProvider(),
    );

    final activeBuild = provider.build(request);
    await provider.cancel(request.id);
    pending.complete(_advance(
      WorkshopDurableFinalBuildDisposition.completed,
      buildResult: _success(request),
    ));
    final result = await activeBuild;
    expect(result.status, WorkshopBuildStatus.cancelled);
    expect(result.requestId, request.id);
  });

  test('cancellation during failed remote observation wins over error',
      () async {
    final pending = Completer<WorkshopDurableFinalBuildAdvance>();
    final request = _request('cancel-during-error');
    final provider = WorkshopDurableGitHubBuildProvider(
      advance: (request) => pending.future,
      toolchainDelegate: _ToolchainProvider(),
    );

    final activeBuild = provider.build(request);
    await provider.cancel(request.id);
    pending.completeError(StateError('late GitHub observation error'));
    final result = await activeBuild;
    expect(result.status, WorkshopBuildStatus.cancelled);
    expect(result.errors, isEmpty);
  });

  test('unmatched late CI failure cannot trigger generated-project repair',
      () async {
    final request = _request('unmatched-event');
    final now = DateTime.utc(2026, 10, 3, 20);
    final failure = WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.failed,
      startedAt: now,
      finishedAt: now,
      errors: const <String>['durable_artifact_validation_failed'],
    );
    const unmatchedKey = 'late-old-attempt-completion';
    final provider = WorkshopDurableGitHubBuildProvider(
      advance: (request) async => _advance(
        WorkshopDurableFinalBuildDisposition.failed,
        buildResult: failure,
        events: <WorkshopDurableExternalEvent>[
          WorkshopDurableExternalEvent(
            type: 'ci.completed',
            projectId: 'durable-final-build:test',
            taskId: 'final-build',
            correlationId: 'test',
            idempotencyKey: unmatchedKey,
            occurredAt: now,
            success: false,
            failureClass: WorkshopDurableFailureClass.buildError,
            externalId: '10',
          ),
        ],
      ),
      toolchainDelegate: _ToolchainProvider(),
    );
    final result = await provider.build(request);
    expect(result.status, WorkshopBuildStatus.failed);
    expect(result.errors, contains('durable_artifact_validation_failed'));
    expect(result.errors, isNot(contains('remote_project_build_failed')));
  });

  test('processed older buildError does not trigger current attempt repair',
      () async {
    final request = _request('older-processed-build-error');
    final now = DateTime.utc(2026, 10, 3, 20);
    const projectId = 'durable-final-build:test';
    const oldStart = 'github:durable-final-build:test:final-build:run:10:started';
    const oldDone = 'github:durable-final-build:test:final-build:run:10:completed';
    const currentStart = 'github:durable-final-build:test:final-build:run:20:started';
    const currentDone = 'github:durable-final-build:test:final-build:run:20:completed';
    final events = <WorkshopDurableExternalEvent>[
      WorkshopDurableExternalEvent(
        type: 'ci.started',
        projectId: projectId,
        taskId: 'final-build',
        correlationId: 'test',
        idempotencyKey: oldStart,
        occurredAt: now,
        success: true,
        externalId: 'test:attempt:1',
      ),
      WorkshopDurableExternalEvent(
        type: 'ci.completed',
        projectId: projectId,
        taskId: 'final-build',
        correlationId: 'test',
        idempotencyKey: oldDone,
        occurredAt: now,
        success: false,
        failureClass: WorkshopDurableFailureClass.buildError,
        externalId: '10',
      ),
      WorkshopDurableExternalEvent(
        type: 'ci.started',
        projectId: projectId,
        taskId: 'final-build',
        correlationId: 'test',
        idempotencyKey: currentStart,
        occurredAt: now,
        success: true,
        externalId: 'test:attempt:2',
      ),
      WorkshopDurableExternalEvent(
        type: 'ci.completed',
        projectId: projectId,
        taskId: 'final-build',
        correlationId: 'test',
        idempotencyKey: currentDone,
        occurredAt: now,
        success: false,
        failureClass: WorkshopDurableFailureClass.policyBlocked,
        externalId: '20',
      ),
    ];
    final failure = WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.failed,
      startedAt: now,
      finishedAt: now,
      errors: const <String>['durable_policy_blocked'],
    );
    final provider = WorkshopDurableGitHubBuildProvider(
      advance: (request) async => _advance(
        WorkshopDurableFinalBuildDisposition.failed,
        buildResult: failure,
        events: events,
        attemptsStarted: 2,
        processedKeys: const <String>{
          oldStart, oldDone, currentStart, currentDone,
        },
      ),
      toolchainDelegate: _ToolchainProvider(),
    );
    final result = await provider.build(request);
    expect(result.errors, contains('durable_policy_blocked'));
    expect(result.errors, isNot(contains('remote_project_build_failed')));
  });

  test('current processed buildError preserves automatic Reviewer repair',
      () async {
    final request = _request('current-build-error');
    final now = DateTime.utc(2026, 10, 3, 20);
    const start = 'github:durable-final-build:test:final-build:run:20:started';
    const done = 'github:durable-final-build:test:final-build:run:20:completed';
    final failure = WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.failed,
      startedAt: now,
      finishedAt: now,
      errors: const <String>['durable_remote_build_failed'],
    );
    final provider = WorkshopDurableGitHubBuildProvider(
      advance: (request) async => _advance(
        WorkshopDurableFinalBuildDisposition.failed,
        buildResult: failure,
        attemptsStarted: 2,
        processedKeys: const <String>{start, done},
        events: <WorkshopDurableExternalEvent>[
          WorkshopDurableExternalEvent(
            type: 'ci.started',
            projectId: 'durable-final-build:test',
            taskId: 'final-build',
            correlationId: 'test',
            idempotencyKey: start,
            occurredAt: now,
            success: true,
            externalId: 'test:attempt:2',
          ),
          WorkshopDurableExternalEvent(
            type: 'ci.completed',
            projectId: 'durable-final-build:test',
            taskId: 'final-build',
            correlationId: 'test',
            idempotencyKey: done,
            occurredAt: now,
            success: false,
            failureClass: WorkshopDurableFailureClass.buildError,
            externalId: '20',
          ),
        ],
      ),
      toolchainDelegate: _ToolchainProvider(),
    );
    final result = await provider.build(request);
    expect(result.errors, <String>['remote_project_build_failed']);
  });

  test('toolchain inspection is delegated without invoking durable build',
      () async {
    var advances = 0;
    final delegate = _ToolchainProvider();
    final provider = WorkshopDurableGitHubBuildProvider(
      advance: (request) async {
        advances += 1;
        return _advance(WorkshopDurableFinalBuildDisposition.failed);
      },
      toolchainDelegate: delegate,
    );

    final info = await provider.inspectToolchain(WorkshopBuildTarget.android);

    expect(info.isAvailable, isTrue);
    expect(info.executionMode, WorkshopBuildExecutionMode.remote);
    expect(delegate.inspections, 1);
    expect(advances, 0);
  });

  test('unexpected driver exception becomes explicit failed build result',
      () async {
    final request = _request('throws');
    final provider = WorkshopDurableGitHubBuildProvider(
      advance: (request) async => throw StateError('broken durable state'),
      toolchainDelegate: _ToolchainProvider(),
      delay: (_) async {},
    );

    final result = await provider.build(request);

    expect(result.status, WorkshopBuildStatus.failed);
    expect(result.errors, contains('durable_final_build_driver_failed'));
    expect(result.message, contains('broken durable state'));
  });
}

WorkshopDurableFinalBuildAdvance _advance(
  WorkshopDurableFinalBuildDisposition disposition, {
  WorkshopBuildResult? buildResult,
  List<WorkshopDurableExternalEvent> events = const <WorkshopDurableExternalEvent>[],
  Set<String> processedKeys = const <String>{},
  int attemptsStarted = 0,
}) {
  final now = DateTime.utc(2026, 10, 3, 20);
  final state = switch (disposition) {
    WorkshopDurableFinalBuildDisposition.completed =>
      WorkshopDurableState.completed,
    WorkshopDurableFinalBuildDisposition.failed => WorkshopDurableState.failed,
    WorkshopDurableFinalBuildDisposition.cancelled =>
      WorkshopDurableState.cancelled,
    WorkshopDurableFinalBuildDisposition.finalizing =>
      WorkshopDurableState.validating,
    WorkshopDurableFinalBuildDisposition.retrying =>
      WorkshopDurableState.retrying,
    WorkshopDurableFinalBuildDisposition.dispatched ||
    WorkshopDurableFinalBuildDisposition.waitingForRun ||
    WorkshopDurableFinalBuildDisposition.waitingForCompletion =>
      WorkshopDurableState.waitingExternal,
  };
  return WorkshopDurableFinalBuildAdvance(
    snapshot: WorkshopDurableProjectSnapshot(
      projectId: 'durable-final-build:test',
      correlationId: 'test',
      state: state,
      createdAt: now,
      updatedAt: now,
      events: events,
      processedIdempotencyKeys: processedKeys,
      tasks: <String, WorkshopDurableTask>{
        'final-build': WorkshopDurableTask(
          taskId: 'final-build',
          capability: 'build.android',
          state: state,
          updatedAt: now,
          attemptsStarted: attemptsStarted,
        ),
      },
    ),
    disposition: disposition,
    buildResult: buildResult,
  );
}

WorkshopBuildRequest _request(String id) => WorkshopBuildRequest(
      id: id,
      projectId: 'project-1',
      projectPath: '/workspace/project-1',
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.automatic,
    );

WorkshopBuildResult _success(WorkshopBuildRequest request) {
  final now = DateTime.utc(2026, 10, 3, 20);
  return WorkshopBuildResult(
    requestId: request.id,
    target: request.target,
    status: WorkshopBuildStatus.succeeded,
    startedAt: now,
    finishedAt: now,
    artifactPath: '/tmp/app-release.apk',
    testsPassed: true,
    analysisPassed: true,
    formatPassed: true,
  );
}

final class _ToolchainProvider implements WorkshopBuildProvider {
  int inspections = 0;

  @override
  WorkshopBuildExecutionMode get executionMode =>
      WorkshopBuildExecutionMode.remote;

  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) async {
    inspections += 1;
    return WorkshopToolchainInfo(
      target: target,
      status: WorkshopToolchainStatus.available,
      executionMode: executionMode,
      name: 'fake remote',
    );
  }

  @override
  Future<WorkshopBuildResult> build(WorkshopBuildRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<void> cancel(String requestId) async {}
}
