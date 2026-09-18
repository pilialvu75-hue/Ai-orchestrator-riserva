import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_execution_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

void main() {
  test('one execution is shared by multiple observers', () async {
    final result = _result();
    final runner = _ControlledRunner(_handle());
    final controller = WorkshopProductionExecutionController(runner: runner);

    final first = controller.start();
    final second = controller.start();

    expect(identical(first, second), isTrue);
    expect(runner.runCount, 1);
    expect(controller.state.status, WorkshopProductionExecutionStatus.running);

    runner.complete(result);
    await first;

    expect(controller.state.status, WorkshopProductionExecutionStatus.succeeded);
    expect(identical(controller.state.result, result), isTrue);
    expect(controller.state.finishedAt, isNotNull);
    expect(controller.state.canRetry, isFalse);

    controller.dispose();
  });

  test('cancellation belongs to execution lifecycle, not a widget', () async {
    final runner = _ControlledRunner(_handle());
    final controller = WorkshopProductionExecutionController(runner: runner);

    final run = controller.start();
    controller.cancel();

    expect(controller.state.status, WorkshopProductionExecutionStatus.cancelling);
    expect(runner.token?.isCancelled, isTrue);

    runner.complete(_result());
    await run;

    expect(controller.state.status, WorkshopProductionExecutionStatus.cancelled);
    expect(controller.state.result, isNull);
    expect(controller.state.canRetry, isTrue);

    controller.dispose();
  });

  test('cancelAndWait reaches the cancellation boundary before returning',
      () async {
    final runner = _ControlledRunner(_handle());
    final controller = WorkshopProductionExecutionController(runner: runner);

    controller.start();
    final waiting = controller.cancelAndWait();

    expect(
      controller.state.status,
      WorkshopProductionExecutionStatus.cancelling,
    );
    expect(runner.token?.isCancelled, isTrue);

    runner.complete(_result());
    await waiting;

    expect(
      controller.state.status,
      WorkshopProductionExecutionStatus.cancelled,
    );
    expect(controller.state.isRunning, isFalse);

    controller.dispose();
  });

  test('failed offline execution retries offline without duplicating active work',
      () async {
    final runner = _RetryRunner(_handle());
    final controller = WorkshopProductionExecutionController(runner: runner);

    await expectLater(controller.start(isOffline: true), throwsStateError);
    expect(controller.state.status, WorkshopProductionExecutionStatus.failed);
    expect(controller.state.canRetry, isTrue);
    expect(controller.state.isOffline, isTrue);
    expect(runner.runCount, 1);
    expect(runner.offlineModes, <bool>[true]);

    final retried = controller.retry();
    expect(controller.state.status, WorkshopProductionExecutionStatus.running);
    expect(controller.state.isOffline, isTrue);
    expect(runner.runCount, 2);

    final result = await retried;
    expect(result.review.summary, 'Test verdict.');
    expect(runner.offlineModes, <bool>[true, true]);
    expect(controller.state.status, WorkshopProductionExecutionStatus.succeeded);
    expect(controller.state.canRetry, isFalse);
    expect(controller.state.isOffline, isTrue);

    controller.dispose();
  });

  test('explicit offline execution is forwarded to the production runner',
      () async {
    final runner = _ControlledRunner(_handle());
    final controller = WorkshopProductionExecutionController(runner: runner);

    final run = controller.start(isOffline: true);

    expect(runner.isOffline, isTrue);
    expect(controller.state.isOffline, isTrue);

    runner.complete(_result());
    await run;

    controller.dispose();
  });

  test('distinct task guard is bounded per project and resets for a new plan',
      () async {
    final runner = _ImmediateRunner(_handle());
    final controller = WorkshopProductionExecutionController(
      runner: runner,
      policy: const WorkshopProductionExecutionPolicy(
        maxDistinctTasksPerProject: 1,
      ),
    );

    await controller.start();
    expect(controller.distinctTasksStartedInCurrentProject, 1);

    controller.reset();
    runner.handle = _handle(taskId: 'task-2');
    expect(controller.start, throwsStateError);
    expect(controller.distinctTasksStartedInCurrentProject, 1);

    runner.handle = _handle(
      taskId: 'task-2',
      planId: 'project:request-2',
    );
    await controller.start();
    expect(controller.distinctTasksStartedInCurrentProject, 1);

    controller.dispose();
  });

  test('retry is rejected when execution is not terminally retryable', () {
    final runner = _ControlledRunner(_handle());
    final controller = WorkshopProductionExecutionController(runner: runner);

    expect(controller.retry, throwsStateError);

    controller.dispose();
  });
}

final class _ControlledRunner implements WorkshopProductionExecutionRunner {
  _ControlledRunner(this.handle);

  final WorkshopProductionTaskHandle handle;
  final Completer<WorkshopTaskInferenceResult> _completer =
      Completer<WorkshopTaskInferenceResult>();
  int runCount = 0;
  CancellationToken? token;
  bool? isOffline;

  @override
  WorkshopProductionTaskHandle preparedHandle() => handle;

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) {
    runCount += 1;
    token = cancellationToken;
    this.isOffline = isOffline;
    return _completer.future;
  }

  void complete(WorkshopTaskInferenceResult result) {
    _completer.complete(result);
  }
}

final class _RetryRunner implements WorkshopProductionExecutionRunner {
  _RetryRunner(this.handle);

  final WorkshopProductionTaskHandle handle;
  int runCount = 0;
  final List<bool> offlineModes = <bool>[];

  @override
  WorkshopProductionTaskHandle preparedHandle() => handle;

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) async {
    runCount += 1;
    offlineModes.add(isOffline);
    if (runCount == 1) {
      throw StateError('transient inference failure');
    }
    return _result();
  }
}

final class _ImmediateRunner implements WorkshopProductionExecutionRunner {
  _ImmediateRunner(this.handle);

  WorkshopProductionTaskHandle handle;

  @override
  WorkshopProductionTaskHandle preparedHandle() => handle;

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) async {
    return _result();
  }
}

WorkshopProductionTaskHandle _handle({
  String taskId = 'task-1',
  String planId = 'project:request-1',
}) {
  const request = WorkshopRequest(
    id: 'request-1',
    title: 'Test',
    instruction: 'Test execution lifecycle.',
  );
  final plan = WorkshopProjectPlan(
    id: planId,
    title: 'Test',
    goal: 'Test execution lifecycle.',
  );
  final session = WorkspaceSession(
    request: request,
    gateway: _FakeGateway(),
  );
  return WorkshopProductionTaskHandle(
    plan: plan,
    taskId: taskId,
    session: session,
  );
}

WorkshopTaskInferenceResult _result() {
  return const WorkshopTaskInferenceResult(
    proposal: WorkshopChangeProposal(
      requestId: 'request-1',
      explanation: 'No changes required.',
      changes: <WorkspaceFileChange>[],
    ),
    review: WorkshopReviewVerdict(
      approved: false,
      summary: 'Test verdict.',
    ),
  );
}

final class _FakeGateway implements GitWorkspaceGateway {
  @override
  Future<String> commit(String message) async => 'commit';

  @override
  Future<void> createBranch(String branchName) async {}

  @override
  Future<String> createPullRequest({
    required String title,
    required String body,
    required String headBranch,
    required String baseBranch,
  }) async => 'pr';

  @override
  Future<void> deleteFile(String path) async {}

  @override
  Future<bool> fileExists(String path) async => false;

  @override
  Future<GitWorkspaceDiff> getDiff() async =>
      const GitWorkspaceDiff(files: <GitWorkspaceFileChange>[]);

  @override
  Future<List<String>> listFiles({String? directory}) async => const <String>[];

  @override
  Future<GitWorkspaceInfo> openWorkspace() async => const GitWorkspaceInfo(
        repository: 'test',
        branch: 'main',
      );

  @override
  Future<void> push() async {}

  @override
  Future<String?> readFile(String path) async => null;

  @override
  Future<void> writeFile({
    required String path,
    required String content,
  }) async {}
}
