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
      tasks: <String, WorkshopDurableTask>{
        'final-build': WorkshopDurableTask(
          taskId: 'final-build',
          capability: 'build.android',
          state: state,
          updatedAt: now,
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
