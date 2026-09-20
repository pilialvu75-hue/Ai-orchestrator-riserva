import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_execution.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_execution_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_validated_proposal_snapshot.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('resetForNextTask preserves explicit offline execution mode', () async {
    final runner = _ImmediateRunner(_handle());
    final controller = WorkshopProductionExecutionController(runner: runner);

    await controller.start(isOffline: true);
    controller.resetForNextTask();

    expect(controller.state.status, WorkshopProductionExecutionStatus.idle);
    expect(controller.state.isOffline, isTrue);

    controller.reset();
    expect(controller.state.isOffline, isFalse);

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

  test('build repair budget stops repeated failures before consuming a slot', () {
    final runner = _ImmediateRunner(_handle());
    final controller = WorkshopProductionExecutionController(
      runner: runner,
      policy: const WorkshopProductionExecutionPolicy(
        maxBuildRepairAttempts: 2,
      ),
    );

    expect(
      controller.reserveBuildRepairAttempt(
        rootProjectId: 'project:root',
        failureSignature: 'failure-a',
      ),
      WorkshopBuildRepairReservation.reserved,
    );
    expect(controller.buildRepairAttempts, 1);
    expect(controller.buildRepairRootProjectId, 'project:root');
    expect(controller.lastBuildRepairFailureSignature, 'failure-a');

    controller.resetForNextTask();
    expect(
      controller.reserveBuildRepairAttempt(
        rootProjectId: 'project:root',
        failureSignature: 'failure-a',
      ),
      WorkshopBuildRepairReservation.repeatedFailure,
    );
    expect(controller.buildRepairAttempts, 1);

    expect(
      controller.reserveBuildRepairAttempt(
        rootProjectId: 'project:root',
        failureSignature: 'failure-b',
      ),
      WorkshopBuildRepairReservation.reserved,
    );
    expect(controller.buildRepairAttempts, 2);
    expect(
      controller.reserveBuildRepairAttempt(
        rootProjectId: 'project:root',
        failureSignature: 'failure-c',
      ),
      WorkshopBuildRepairReservation.budgetExhausted,
    );
    expect(controller.buildRepairAttempts, 2);

    expect(
      controller.reserveBuildRepairAttempt(
        rootProjectId: 'project:new-root',
        failureSignature: 'failure-c',
      ),
      WorkshopBuildRepairReservation.reserved,
    );
    expect(controller.buildRepairAttempts, 1);
    expect(controller.buildRepairRootProjectId, 'project:new-root');

    controller.clearBuildRepairChain();
    expect(controller.buildRepairAttempts, 0);
    expect(controller.buildRepairRootProjectId, isNull);
    expect(controller.lastBuildRepairFailureSignature, isNull);

    controller.dispose();
  });

  test('persistent journal keeps one execution and distinct retry attempts',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = WorkshopExecutionStore(preferences: preferences);
    final runner = _RetryRunner(_handle());
    final controller = WorkshopProductionExecutionController(
      runner: runner,
      executionStore: store,
    );

    await expectLater(
      controller.start(isOffline: true),
      throwsStateError,
    );

    final firstCurrent = (await store.loadAll()).single;
    expect(firstCurrent.status, WorkshopExecutionStatus.failed);
    expect(firstCurrent.resource, WorkshopTaskResource.local);
    expect(firstCurrent.providerId, isNull);
    expect(firstCurrent.modelId, isNull);
    expect(firstCurrent.metadata['multiRole'], isTrue);
    expect(firstCurrent.metadata['offline'], isTrue);
    expect(firstCurrent.metadata['failureType'], 'StateError');
    final stableExecutionId = firstCurrent.executionId;
    final firstAttemptId = firstCurrent.attemptId;

    await controller.retry();

    final secondCurrent = (await store.loadAll()).single;
    final attempts = await store.loadAttempts(stableExecutionId);
    expect(secondCurrent.executionId, stableExecutionId);
    expect(secondCurrent.attemptId, isNot(firstAttemptId));
    expect(secondCurrent.status, WorkshopExecutionStatus.checkpointed);
    expect(secondCurrent.resumePhase, 'review');
    expect(secondCurrent.checkpointId, isNotNull);
    final retryCheckpoint = WorkshopTaskCheckpoint.fromJson(
      Map<String, dynamic>.from(
        secondCurrent.metadata['taskCheckpoint'] as Map,
      ),
    );
    expect(retryCheckpoint.id, secondCurrent.checkpointId);
    expect(retryCheckpoint.phase, 'review');
    expect(retryCheckpoint.completedSteps, isEmpty);
    expect(retryCheckpoint.changedFiles, isEmpty);
    expect(
      retryCheckpoint.metadata['remainingWork'],
      contains('re-establish implementation against the current workspace'),
    );
    expect(secondCurrent.metadata['semanticResume'], isTrue);
    expect(secondCurrent.metadata['previousStatus'], 'failed');
    expect(secondCurrent.metadata['previousResumePhase'], 'failed');
    expect(runner.resumeContexts, hasLength(1));
    expect(runner.resumeContexts.single.executionId, stableExecutionId);
    expect(runner.resumeContexts.single.attemptId, secondCurrent.attemptId);
    expect(runner.resumeContexts.single.taskId, 'task-1');
    expect(runner.resumeContexts.single.phase, 'failed');
    expect(
      runner.resumeContexts.single.remainingWork,
      contains('re-establish implementation against the current workspace'),
    );
    expect(attempts, hasLength(2));
    expect(
      attempts.map((attempt) => attempt.executionId).toSet(),
      <String>{stableExecutionId},
    );
    expect(
      attempts.map((attempt) => attempt.attemptId).toSet().length,
      2,
    );
    expect(controller.executionJournalError, isNull);

    controller.dispose();
  });

  test('journal completes only after the guarded apply boundary', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = WorkshopExecutionStore(preferences: preferences);
    final runner = _ReadyRunner(_handle());
    final controller = WorkshopProductionExecutionController(
      runner: runner,
      executionStore: store,
    );

    await controller.start();

    final waiting = (await store.loadAll()).single;
    expect(waiting.status, WorkshopExecutionStatus.waitingApproval);
    expect(waiting.resumePhase, 'waitingApproval');
    expect(waiting.checkpointId, isNotNull);
    final waitingCheckpoint = WorkshopTaskCheckpoint.fromJson(
      Map<String, dynamic>.from(
        waiting.metadata['taskCheckpoint'] as Map,
      ),
    );
    expect(waitingCheckpoint.id, waiting.checkpointId);
    expect(waitingCheckpoint.phase, 'waitingApproval');
    expect(waitingCheckpoint.completedSteps, isEmpty);
    expect(waitingCheckpoint.changedFiles, isEmpty);
    expect(
      waitingCheckpoint.metadata['decisions'],
      contains(
        'Validated workspace snapshot was unavailable; replay must '
        're-establish implementation, review and validation.',
      ),
    );
    expect(waiting.resource, WorkshopTaskResource.hybridAi);
    expect(waiting.providerId, isNull);
    expect(waiting.modelId, isNull);
    expect(waiting.accountId, isNull);
    expect(waiting.metadata['multiRole'], isTrue);
    expect(waiting.metadata['offline'], isFalse);
    expect(controller.journalExecution, isNotNull);

    await controller.markCurrentExecutionCompleted();

    final completed = (await store.loadAll()).single;
    expect(completed.status, WorkshopExecutionStatus.completed);
    expect(completed.resumePhase, 'completed');
    expect(controller.journalExecution, isNull);

    controller.dispose();
  });

  test('abandon persists cancellation before forgetting the journal', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = WorkshopExecutionStore(preferences: preferences);
    final controller = WorkshopProductionExecutionController(
      runner: _ReadyRunner(_handle()),
      executionStore: store,
    );

    await controller.start();
    expect((await store.loadAll()).single.status,
        WorkshopExecutionStatus.waitingApproval);

    await controller.abandonCurrentExecution();

    final cancelled = (await store.loadAll()).single;
    expect(cancelled.status, WorkshopExecutionStatus.cancelled);
    expect(cancelled.resumePhase, 'cancelled');
    expect(controller.journalExecution, isNull);
    expect(controller.executionJournalError, isNull);

    controller.dispose();
  });

  test(
      'restart reuses logical execution with a new attempt and safe replay',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = WorkshopExecutionStore(preferences: preferences);
    final handle = _handle();
    final original = await store.create(
      projectId: handle.plan.id,
      taskId: handle.taskId,
      sessionId: 'production:${handle.plan.id}:${handle.taskId}',
      resource: WorkshopTaskResource.local,
      metadata: const <String, dynamic>{
        'surface': 'workshop-production',
        'multiRole': true,
        'offline': true,
      },
    );
    final waiting = original.copyWith(
      status: WorkshopExecutionStatus.waitingApproval,
      resumePhase: 'waitingApproval',
    );
    await store.save(waiting);

    final runner = _ControlledRunner(handle);
    final controller = WorkshopProductionExecutionController(
      runner: runner,
      executionStore: store,
    );

    final recovery =
        await controller.restorePersistentExecutionForPreparedTask();

    expect(recovery, isNotNull);
    expect(
      recovery!.disposition,
      WorkshopProductionExecutionRecoveryDisposition.safeReplayPending,
    );
    expect(recovery.execution.executionId, original.executionId);
    expect(controller.restartReplayPending, isTrue);
    expect(controller.state.status, WorkshopProductionExecutionStatus.idle);
    expect(controller.state.isOffline, isTrue);
    expect(controller.distinctTasksStartedInCurrentProject, 1);

    final run = controller.start(isOffline: controller.state.isOffline);
    await runner.started;
    expect(runner.runCount, 1);
    runner.complete(_result());
    await run;

    final current = (await store.loadAll()).single;
    final attempts = await store.loadAttempts(original.executionId);
    expect(current.executionId, original.executionId);
    expect(current.attemptId, isNot(original.attemptId));
    expect(current.status, WorkshopExecutionStatus.checkpointed);
    expect(current.metadata['semanticResume'], isTrue);
    expect(current.metadata['processRestartResume'], isTrue);
    expect(current.metadata['previousStatus'], 'waitingApproval');
    expect(current.metadata['previousResumePhase'], 'waitingApproval');
    expect(runner.resumeContexts, hasLength(1));
    final resume = runner.resumeContexts.single;
    expect(resume.executionId, original.executionId);
    expect(resume.attemptId, current.attemptId);
    expect(resume.projectId, handle.plan.id);
    expect(resume.taskId, handle.taskId);
    expect(resume.phase, 'waitingApproval');
    expect(resume.completedSteps, isEmpty);
    expect(resume.verified, isEmpty);
    expect(
      resume.remainingWork,
      contains('re-establish implementation against the current workspace'),
    );
    expect(resume.remainingWork, contains('owner approval'));
    expect(attempts, hasLength(2));
    expect(controller.restartReplayPending, isFalse);

    controller.dispose();
  });

  test('failed execution restores as explicit retry on the same execution',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = WorkshopExecutionStore(preferences: preferences);
    final handle = _handle();
    final original = await store.create(
      projectId: handle.plan.id,
      taskId: handle.taskId,
      sessionId: 'production:${handle.plan.id}:${handle.taskId}',
      resource: WorkshopTaskResource.hybridAi,
      metadata: const <String, dynamic>{
        'surface': 'workshop-production',
        'multiRole': true,
        'offline': false,
      },
    );
    await store.save(
      original.copyWith(
        status: WorkshopExecutionStatus.failed,
        resumePhase: 'failed',
      ),
    );

    final controller = WorkshopProductionExecutionController(
      runner: _ImmediateRunner(handle),
      executionStore: store,
    );
    final recovery =
        await controller.restorePersistentExecutionForPreparedTask();

    expect(
      recovery?.disposition,
      WorkshopProductionExecutionRecoveryDisposition.retryAvailable,
    );
    expect(controller.state.status, WorkshopProductionExecutionStatus.failed);
    expect(controller.state.canRetry, isTrue);
    expect(controller.restartReplayPending, isFalse);

    await controller.retry();

    final current = (await store.loadAll()).single;
    final attempts = await store.loadAttempts(original.executionId);
    expect(current.executionId, original.executionId);
    expect(current.attemptId, isNot(original.attemptId));
    expect(attempts, hasLength(2));

    controller.dispose();
  });

  test('completed execution plus active recovered task is blocked fail closed',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = WorkshopExecutionStore(preferences: preferences);
    final handle = _handle();
    final original = await store.create(
      projectId: handle.plan.id,
      taskId: handle.taskId,
      sessionId: 'production:${handle.plan.id}:${handle.taskId}',
      resource: WorkshopTaskResource.hybridAi,
      metadata: const <String, dynamic>{
        'surface': 'workshop-production',
        'multiRole': true,
        'offline': false,
      },
    );
    await store.save(
      original.copyWith(
        status: WorkshopExecutionStatus.completed,
        resumePhase: 'completed',
      ),
    );

    final controller = WorkshopProductionExecutionController(
      runner: _ImmediateRunner(handle),
      executionStore: store,
    );

    await expectLater(
      controller.restorePersistentExecutionForPreparedTask(),
      throwsA(isA<StateError>()),
    );
    expect(controller.journalExecution, isNull);
    expect(controller.state.status, WorkshopProductionExecutionStatus.idle);

    controller.dispose();
  });

  test(
      'validated snapshot restores approval-ready state without rerunning AI',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = WorkshopExecutionStore(preferences: preferences);
    final recoveryRoot = await Directory.systemTemp.createTemp(
      'workshop-execution-resume-',
    );
    final snapshotService = WorkshopValidatedProposalSnapshotService(
      snapshotsRootPath: recoveryRoot.path,
    );

    try {
      final firstHandle = await _initializedSnapshotHandle();
      final firstRunner = _SnapshotReadyRunner(firstHandle);
      final firstController = WorkshopProductionExecutionController(
        runner: firstRunner,
        executionStore: store,
        validatedProposalSnapshotService: snapshotService,
      );

      await firstController.start();

      expect(firstRunner.runCount, 1);
      final waiting = (await store.loadAll()).single;
      expect(waiting.status, WorkshopExecutionStatus.waitingApproval);
      final snapshot =
          WorkshopValidatedProposalSnapshot.fromExecutionMetadata(
        waiting.metadata,
      );
      final durableCheckpoint = WorkshopTaskCheckpoint.fromJson(
        Map<String, dynamic>.from(
          waiting.metadata['taskCheckpoint'] as Map,
        ),
      );
      expect(waiting.checkpointId, durableCheckpoint.id);
      expect(durableCheckpoint.phase, 'waitingApproval');
      expect(
        durableCheckpoint.completedSteps,
        <String>['implementation', 'review', 'validation'],
      );
      expect(
        durableCheckpoint.changedFiles,
        <String>['lib/app.dart', 'lib/reused.dart'],
      );
      expect(
        durableCheckpoint.metadata['remainingWork'],
        <String>['owner approval', 'guarded apply'],
      );
      expect(
        durableCheckpoint.metadata['artifacts'],
        <String>['validated-proposal-snapshot'],
      );
      expect(await Directory(snapshot.rootPath).exists(), isTrue);
      expect(firstHandle.session.status, WorkspaceSessionStatus.validation);
      expect(firstHandle.session.isApplyApproved, isFalse);
      firstController.dispose();

      final restoredHandle = await _initializedSnapshotHandle();
      final restoredRunner = _ImmediateRunner(restoredHandle);
      final restoredController = WorkshopProductionExecutionController(
        runner: restoredRunner,
        executionStore: store,
        validatedProposalSnapshotService: snapshotService,
      );

      final recovery =
          await restoredController.restorePersistentExecutionForPreparedTask();

      expect(
        recovery?.disposition,
        WorkshopProductionExecutionRecoveryDisposition
            .validatedApprovalRecovered,
      );
      expect(restoredRunner.runCount, 0);
      expect(
        restoredController.state.status,
        WorkshopProductionExecutionStatus.succeeded,
      );
      expect(restoredController.state.result?.readyForApproval, isTrue);
      expect(restoredController.restartReplayPending, isFalse);
      expect(restoredController.recoverySnapshotError, isNull);
      expect(restoredHandle.session.status, WorkspaceSessionStatus.validation);
      expect(restoredHandle.session.isApplyApproved, isFalse);
      expect(restoredHandle.session.workspace.read('lib/app.dart'),
          'int answer = 42;\n');
      expect(restoredHandle.session.workspace.read('lib/reused.dart'),
          'String reused = "library";\n');
      expect(
        (await store.loadAttempts(waiting.executionId)),
        hasLength(1),
      );

      restoredController.dispose();
    } finally {
      if (await recoveryRoot.exists()) {
        await recoveryRoot.delete(recursive: true);
      }
    }
  });

  test(
      'stale validated snapshot falls back to a new attempt and drops descriptor',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final store = WorkshopExecutionStore(preferences: preferences);
    final recoveryRoot = await Directory.systemTemp.createTemp(
      'workshop-execution-stale-resume-',
    );
    final snapshotService = WorkshopValidatedProposalSnapshotService(
      snapshotsRootPath: recoveryRoot.path,
    );

    try {
      final firstHandle = await _initializedSnapshotHandle();
      final firstController = WorkshopProductionExecutionController(
        runner: _SnapshotReadyRunner(firstHandle),
        executionStore: store,
        validatedProposalSnapshotService: snapshotService,
      );
      await firstController.start();

      final waiting = (await store.loadAll()).single;
      final oldSnapshot =
          WorkshopValidatedProposalSnapshot.fromExecutionMetadata(
        waiting.metadata,
      );
      firstController.dispose();

      final changedHandle = await _initializedSnapshotHandle(
        baseline: 'int answer = 7;\n',
      );
      final changedRunner = _ImmediateRunner(changedHandle);
      final changedController = WorkshopProductionExecutionController(
        runner: changedRunner,
        executionStore: store,
        validatedProposalSnapshotService: snapshotService,
      );

      final recovery =
          await changedController.restorePersistentExecutionForPreparedTask();

      expect(
        recovery?.disposition,
        WorkshopProductionExecutionRecoveryDisposition.safeReplayPending,
      );
      expect(
        changedController.recoverySnapshotError,
        isA<WorkshopValidatedProposalBaselineConflict>(),
      );
      expect(changedController.restartReplayPending, isTrue);
      expect(changedController.state.status, WorkshopProductionExecutionStatus.idle);
      expect(changedHandle.session.hasChanges, isFalse);

      await changedController.start(
        isOffline: changedController.state.isOffline,
      );

      final current = (await store.loadAll()).single;
      final attempts = await store.loadAttempts(waiting.executionId);
      expect(changedRunner.runCount, 1);
      expect(current.executionId, waiting.executionId);
      expect(current.attemptId, isNot(waiting.attemptId));
      expect(current.metadata.containsKey('validatedProposalSnapshot'), isFalse);
      expect(attempts, hasLength(2));
      expect(await Directory(oldSnapshot.rootPath).exists(), isFalse);

      changedController.dispose();
    } finally {
      if (await recoveryRoot.exists()) {
        await recoveryRoot.delete(recursive: true);
      }
    }
  });

  test('retry is rejected when execution is not terminally retryable', () {
    final runner = _ControlledRunner(_handle());
    final controller = WorkshopProductionExecutionController(runner: runner);

    expect(controller.retry, throwsStateError);

    controller.dispose();
  });
}

final class _ControlledRunner
    implements
        WorkshopProductionExecutionRunner,
        WorkshopProductionSemanticResumeRunner {
  _ControlledRunner(this.handle);

  final WorkshopProductionTaskHandle handle;
  final Completer<WorkshopTaskInferenceResult> _completer =
      Completer<WorkshopTaskInferenceResult>();
  final List<WorkshopResumeContext> resumeContexts = <WorkshopResumeContext>[];
  final Completer<void> _started = Completer<void>();
  int runCount = 0;
  CancellationToken? token;
  bool? isOffline;

  Future<void> get started => _started.future;

  @override
  WorkshopProductionTaskHandle preparedHandle() => handle;

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) {
    return _run(
      cancellationToken: cancellationToken,
      isOffline: isOffline,
    );
  }

  @override
  Future<WorkshopTaskInferenceResult> runPreparedWithResumeContext({
    required WorkshopProductionTaskHandle handle,
    required WorkshopResumeContext resumeContext,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) {
    resumeContexts.add(resumeContext);
    return _run(
      cancellationToken: cancellationToken,
      isOffline: isOffline,
    );
  }

  Future<WorkshopTaskInferenceResult> _run({
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) {
    runCount += 1;
    token = cancellationToken;
    this.isOffline = isOffline;
    if (!_started.isCompleted) {
      _started.complete();
    }
    return _completer.future;
  }

  void complete(WorkshopTaskInferenceResult result) {
    _completer.complete(result);
  }
}

final class _RetryRunner
    implements
        WorkshopProductionExecutionRunner,
        WorkshopProductionSemanticResumeRunner {
  _RetryRunner(this.handle);

  final WorkshopProductionTaskHandle handle;
  int runCount = 0;
  final List<bool> offlineModes = <bool>[];
  final List<WorkshopResumeContext> resumeContexts = <WorkshopResumeContext>[];

  @override
  WorkshopProductionTaskHandle preparedHandle() => handle;

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) {
    return _run(isOffline: isOffline);
  }

  @override
  Future<WorkshopTaskInferenceResult> runPreparedWithResumeContext({
    required WorkshopProductionTaskHandle handle,
    required WorkshopResumeContext resumeContext,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) {
    resumeContexts.add(resumeContext);
    return _run(isOffline: isOffline);
  }

  Future<WorkshopTaskInferenceResult> _run({
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

final class _ReadyRunner implements WorkshopProductionExecutionRunner {
  _ReadyRunner(this.handle);

  final WorkshopProductionTaskHandle handle;

  @override
  WorkshopProductionTaskHandle preparedHandle() => handle;

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) async {
    return _readyResult();
  }
}

final class _ImmediateRunner implements WorkshopProductionExecutionRunner {
  _ImmediateRunner(this.handle);

  WorkshopProductionTaskHandle handle;
  int runCount = 0;

  @override
  WorkshopProductionTaskHandle preparedHandle() => handle;

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) async {
    runCount += 1;
    return _result();
  }
}

final class _SnapshotReadyRunner
    implements WorkshopProductionExecutionRunner {
  _SnapshotReadyRunner(this.handle);

  final WorkshopProductionTaskHandle handle;
  int runCount = 0;

  @override
  WorkshopProductionTaskHandle preparedHandle() => handle;

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) async {
    runCount += 1;
    final session = handle.session;
    session.beginImplementation();
    session.workspace.write(
      path: 'lib/app.dart',
      content: 'int answer = 42;\n',
    );
    session.workspace.write(
      path: 'lib/reused.dart',
      content: 'String reused = "library";\n',
    );
    session.beginReview();
    session.beginValidation();
    return _snapshotReadyResult();
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

Future<WorkshopProductionTaskHandle> _initializedSnapshotHandle({
  String baseline = 'int answer = 0;\n',
}) async {
  const request = WorkshopRequest(
    id: 'request-1',
    title: 'Snapshot test',
    instruction: 'Test validated proposal restart recovery.',
  );
  final plan = WorkshopProjectPlan(
    id: 'project:request-1',
    title: 'Snapshot test',
    goal: 'Test validated proposal restart recovery.',
  );
  final session = WorkspaceSession(
    request: request,
    gateway: _MemoryGateway(<String, String>{
      'lib/app.dart': baseline,
    }),
  );
  await session.initialize();
  return WorkshopProductionTaskHandle(
    plan: plan,
    taskId: 'task-1',
    session: session,
  );
}

WorkshopTaskInferenceResult _snapshotReadyResult() {
  return const WorkshopTaskInferenceResult(
    proposal: WorkshopChangeProposal(
      requestId: 'request-1',
      explanation: 'Validated snapshot proposal.',
      changes: <WorkspaceFileChange>[
        WorkspaceFileChange(
          path: 'lib/app.dart',
          type: WorkspaceChangeType.modification,
          beforeContent: 'int answer = 0;\n',
          afterContent: 'int answer = 42;\n',
        ),
      ],
    ),
    review: WorkshopReviewVerdict(
      approved: true,
      summary: 'Review passed.',
    ),
    validation: WorkshopValidationVerdict(
      valid: true,
      summary: 'Validation passed.',
    ),
  );
}

WorkshopTaskInferenceResult _readyResult() {
  return const WorkshopTaskInferenceResult(
    proposal: WorkshopChangeProposal(
      requestId: 'request-1',
      explanation: 'Validated proposal.',
      changes: <WorkspaceFileChange>[],
    ),
    review: WorkshopReviewVerdict(
      approved: true,
      summary: 'Review passed.',
    ),
    validation: WorkshopValidationVerdict(
      valid: true,
      summary: 'Validation passed.',
    ),
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

final class _MemoryGateway implements GitWorkspaceGateway {
  _MemoryGateway(Map<String, String> files)
      : _files = Map<String, String>.from(files);

  final Map<String, String> _files;

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
  }) async =>
      'pr';

  @override
  Future<void> deleteFile(String path) async {
    _files.remove(path);
  }

  @override
  Future<bool> fileExists(String path) async => _files.containsKey(path);

  @override
  Future<GitWorkspaceDiff> getDiff() async =>
      const GitWorkspaceDiff(files: <GitWorkspaceFileChange>[]);

  @override
  Future<List<String>> listFiles({String? directory}) async =>
      _files.keys.toList(growable: false);

  @override
  Future<GitWorkspaceInfo> openWorkspace() async => const GitWorkspaceInfo(
        repository: 'test',
        branch: 'main',
      );

  @override
  Future<void> push() async {}

  @override
  Future<String?> readFile(String path) async => _files[path];

  @override
  Future<void> writeFile({
    required String path,
    required String content,
  }) async {
    _files[path] = content;
  }
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
