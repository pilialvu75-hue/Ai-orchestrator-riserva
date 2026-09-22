import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_github_actions_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_background_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_github_build_monitor.dart';

void main() {
  group('WorkshopDurableGitHubActionsCoordinator', () {
    late DateTime now;
    late InMemoryWorkshopCheckpointStore checkpointStore;
    late WorkshopDurableOrchestrator orchestrator;
    late _FakeGitHubGateway gateway;
    late WorkshopDurableGitHubActionsCoordinator coordinator;

    setUp(() {
      now = DateTime.utc(2026, 9, 22, 20);
      checkpointStore = InMemoryWorkshopCheckpointStore();
      orchestrator = _orchestrator(checkpointStore, () => now);
      gateway = _FakeGitHubGateway();
      coordinator = WorkshopDurableGitHubActionsCoordinator(
        orchestrator: orchestrator,
        gateway: gateway,
        clock: () => now,
        runDiscoveryTimeout: const Duration(minutes: 2),
        runCompletionTimeout: const Duration(minutes: 30),
      );
    });

    WorkshopBuildRequest request(String id) {
      return WorkshopBuildRequest(
        id: id,
        projectId: 'project-1',
        projectPath: '/tmp/project-1',
        target: WorkshopBuildTarget.android,
        mode: WorkshopBuildExecutionMode.remote,
      );
    }

    WorkshopDurableTask task({
      WorkshopDurableRetryPolicy retryPolicy =
          const WorkshopDurableRetryPolicy(),
    }) {
      return WorkshopDurableTask(
        taskId: 'build-android',
        capability: 'build.android',
        state: WorkshopDurableState.created,
        retryPolicy: retryPolicy,
        timeout: const Duration(minutes: 45),
        completionCriterionIds: const <String>['apk.valid'],
        updatedAt: now,
      );
    }

    Future<void> createReadyProject({
      WorkshopDurableRetryPolicy retryPolicy =
          const WorkshopDurableRetryPolicy(),
    }) async {
      await orchestrator.createProject(
        projectId: 'project-1',
        correlationId: 'corr-project-1',
        tasks: <WorkshopDurableTask>[
          task(retryPolicy: retryPolicy),
        ],
      );
      await orchestrator.markProjectReady('project-1');
    }

    test('persists run-discovery wait before dispatch and never redispatches',
        () async {
      await createReadyProject();

      WorkshopDurableProjectSnapshot? stateObservedInsideDispatch;
      gateway.onDispatch = () async {
        stateObservedInsideDispatch =
            await orchestrator.loadProject('project-1');
      };

      final first = await coordinator.dispatchAndPark(
        projectId: 'project-1',
        taskId: 'build-android',
        operationIdempotencyKey: 'github-build:project-1:android',
        dispatchCorrelationId: 'remote-request-1',
        request: request('request-1'),
      );

      expect(gateway.dispatchCalls, 1);
      expect(
        first.disposition,
        WorkshopDurableGitHubReconcileDisposition.parkedForRunDiscovery,
      );
      expect(
        stateObservedInsideDispatch!.tasks['build-android']!.state,
        WorkshopDurableState.waitingExternal,
      );
      expect(
        stateObservedInsideDispatch!
            .tasks['build-android']!
            .externalWait!
            .eventType,
        WorkshopDurableEventTypes.ciStarted,
      );
      expect(
        stateObservedInsideDispatch!
            .tasks['build-android']!
            .externalWait!
            .externalId,
        'remote-request-1',
      );

      final duplicate = await coordinator.dispatchAndPark(
        projectId: 'project-1',
        taskId: 'build-android',
        operationIdempotencyKey: 'github-build:project-1:android',
        dispatchCorrelationId: 'remote-request-1',
        request: request('request-1'),
      );

      expect(gateway.dispatchCalls, 1);
      expect(
        duplicate.disposition,
        WorkshopDurableGitHubReconcileDisposition.waitingForRunDiscovery,
      );
    });

    test('ambiguous dispatch remains parked for later discovery', () async {
      await createReadyProject();
      gateway.dispatchOutcome =
          WorkshopDurableGitHubDispatchOutcome.ambiguous;

      final result = await coordinator.dispatchAndPark(
        projectId: 'project-1',
        taskId: 'build-android',
        operationIdempotencyKey: 'github-build:ambiguous',
        dispatchCorrelationId: 'remote-ambiguous',
        request: request('request-ambiguous'),
      );

      expect(
        result.snapshot.tasks['build-android']!.state,
        WorkshopDurableState.waitingExternal,
      );
      expect(
        result.disposition,
        WorkshopDurableGitHubReconcileDisposition.parkedForRunDiscovery,
      );
    });

    test('discovers run, restarts, then resumes completion without polling',
        () async {
      await createReadyProject();
      await coordinator.dispatchAndPark(
        projectId: 'project-1',
        taskId: 'build-android',
        operationIdempotencyKey: 'github-build:restart',
        dispatchCorrelationId: 'remote-restart',
        request: request('request-restart'),
      );

      gateway.discoveredRun = _run(
        id: 42,
        status: WorkshopGitHubRunStatus.queued,
      );
      final discovered = await coordinator.reconcile(
        projectId: 'project-1',
        taskId: 'build-android',
        request: request('request-restart'),
      );

      expect(
        discovered.disposition,
        WorkshopDurableGitHubReconcileDisposition.parkedForCompletion,
      );
      expect(discovered.runId, 42);
      expect(
        discovered.snapshot.tasks['build-android']!.state,
        WorkshopDurableState.waitingExternal,
      );
      expect(
        discovered.snapshot.tasks['build-android']!.externalWait!.eventType,
        WorkshopDurableEventTypes.ciCompleted,
      );
      expect(
        discovered.snapshot.tasks['build-android']!.externalWait!.externalId,
        '42',
      );

      final restartedOrchestrator = _orchestrator(
        checkpointStore,
        () => now,
      );
      final restartedCoordinator = WorkshopDurableGitHubActionsCoordinator(
        orchestrator: restartedOrchestrator,
        gateway: gateway,
        clock: () => now,
        runDiscoveryTimeout: const Duration(minutes: 2),
        runCompletionTimeout: const Duration(minutes: 30),
      );

      gateway.currentRun = _run(
        id: 42,
        status: WorkshopGitHubRunStatus.inProgress,
      );
      final stillRunning = await restartedCoordinator.reconcile(
        projectId: 'project-1',
        taskId: 'build-android',
        request: request('request-restart'),
      );

      expect(
        stillRunning.disposition,
        WorkshopDurableGitHubReconcileDisposition.waitingForCompletion,
      );
      expect(gateway.getRunCalls, 1);

      now = now.add(const Duration(minutes: 18));
      gateway.currentRun = _run(
        id: 42,
        status: WorkshopGitHubRunStatus.completed,
        conclusion: WorkshopGitHubRunConclusion.success,
      );
      gateway.artifacts = <WorkshopGitHubArtifact>[
        WorkshopGitHubArtifact(
          id: 9001,
          name: 'android-release',
          archiveDownloadUrl: 'https://api.github.test/artifacts/9001.zip',
          sizeInBytes: 1234,
          expired: false,
        ),
        WorkshopGitHubArtifact(
          id: 9002,
          name: 'expired',
          archiveDownloadUrl: 'https://api.github.test/artifacts/9002.zip',
          sizeInBytes: 10,
          expired: true,
        ),
      ];

      final completed = await restartedCoordinator.reconcile(
        projectId: 'project-1',
        taskId: 'build-android',
        request: request('request-restart'),
      );

      expect(
        completed.disposition,
        WorkshopDurableGitHubReconcileDisposition.validating,
      );
      expect(
        completed.snapshot.tasks['build-android']!.state,
        WorkshopDurableState.validating,
      );
      expect(
        completed.snapshot.tasks['build-android']!.artifactIds,
        const <String>['github-artifact:9001:android-release'],
      );
      expect(gateway.getArtifactsCalls, 1);
    });

    test('build failure follows task-specific retry policy', () async {
      await createReadyProject(
        retryPolicy: const WorkshopDurableRetryPolicy(
          maxAttempts: 2,
          retryableFailures: <WorkshopDurableFailureClass>{
            WorkshopDurableFailureClass.buildError,
          },
        ),
      );
      await coordinator.dispatchAndPark(
        projectId: 'project-1',
        taskId: 'build-android',
        operationIdempotencyKey: 'github-build:retry',
        dispatchCorrelationId: 'remote-retry',
        request: request('request-retry'),
      );

      gateway.discoveredRun = _run(
        id: 77,
        status: WorkshopGitHubRunStatus.inProgress,
      );
      await coordinator.reconcile(
        projectId: 'project-1',
        taskId: 'build-android',
        request: request('request-retry'),
      );

      gateway.currentRun = _run(
        id: 77,
        status: WorkshopGitHubRunStatus.completed,
        conclusion: WorkshopGitHubRunConclusion.failure,
      );
      final failed = await coordinator.reconcile(
        projectId: 'project-1',
        taskId: 'build-android',
        request: request('request-retry'),
      );

      expect(
        failed.disposition,
        WorkshopDurableGitHubReconcileDisposition.retrying,
      );
      expect(
        failed.snapshot.tasks['build-android']!.state,
        WorkshopDurableState.retrying,
      );
      expect(gateway.getArtifactsCalls, 0);
    });

    test('expired run-discovery wait becomes timeout failure', () async {
      await createReadyProject();
      await coordinator.dispatchAndPark(
        projectId: 'project-1',
        taskId: 'build-android',
        operationIdempotencyKey: 'github-build:timeout',
        dispatchCorrelationId: 'remote-timeout',
        request: request('request-timeout'),
      );

      now = now.add(const Duration(minutes: 3));
      gateway.discoveredRun = null;

      final timedOut = await coordinator.reconcile(
        projectId: 'project-1',
        taskId: 'build-android',
        request: request('request-timeout'),
      );

      expect(
        timedOut.disposition,
        WorkshopDurableGitHubReconcileDisposition.failed,
      );
      expect(
        timedOut.snapshot.tasks['build-android']!.state,
        WorkshopDurableState.failed,
      );
    });

    test('definitive dispatch rejection fails without waiting for timeout',
        () async {
      await createReadyProject();
      gateway.dispatchOutcome = const WorkshopDurableGitHubDispatchOutcome(
        disposition: WorkshopDurableGitHubDispatchDisposition.rejected,
        failureClass: WorkshopDurableFailureClass.policyBlocked,
      );

      final result = await coordinator.dispatchAndPark(
        projectId: 'project-1',
        taskId: 'build-android',
        operationIdempotencyKey: 'github-build:rejected',
        dispatchCorrelationId: 'remote-rejected',
        request: request('request-rejected'),
      );

      expect(
        result.disposition,
        WorkshopDurableGitHubReconcileDisposition.failed,
      );
      expect(
        result.snapshot.tasks['build-android']!.state,
        WorkshopDurableState.failed,
      );
    });
  });

  test('chained external wait is persisted atomically with started event',
      () async {
    final now = DateTime.utc(2026, 9, 22, 20);
    final store = InMemoryWorkshopCheckpointStore();
    final orchestrator = _orchestrator(store, () => now);

    await orchestrator.createProject(
      projectId: 'project-chain',
      correlationId: 'corr-chain',
      tasks: <WorkshopDurableTask>[
        WorkshopDurableTask(
          taskId: 'ci',
          capability: 'build.android',
          state: WorkshopDurableState.created,
          updatedAt: now,
        ),
      ],
    );
    await orchestrator.markProjectReady('project-chain');
    await orchestrator.startTask(
      projectId: 'project-chain',
      taskId: 'ci',
    );
    await orchestrator.waitForExternal(
      projectId: 'project-chain',
      taskId: 'ci',
      wait: WorkshopDurableExternalWait(
        eventType: WorkshopDurableEventTypes.ciStarted,
        externalId: 'dispatch-1',
        startedAt: now,
      ),
    );

    final handled = await orchestrator.handleExternalEvent(
      WorkshopDurableExternalEvent(
        type: WorkshopDurableEventTypes.ciStarted,
        projectId: 'project-chain',
        taskId: 'ci',
        correlationId: 'corr-chain',
        idempotencyKey: 'run-11-started',
        occurredAt: now,
        success: true,
        externalId: 'dispatch-1',
      ),
      nextWait: WorkshopDurableExternalWait(
        eventType: WorkshopDurableEventTypes.ciCompleted,
        externalId: '11',
        startedAt: now,
      ),
    );

    expect(handled.matchedTask, isTrue);
    expect(
      handled.snapshot.tasks['ci']!.state,
      WorkshopDurableState.waitingExternal,
    );
    expect(
      handled.snapshot.tasks['ci']!.externalWait!.eventType,
      WorkshopDurableEventTypes.ciCompleted,
    );
    expect(
      handled.snapshot.tasks['ci']!.externalWait!.externalId,
      '11',
    );
    expect(
      handled.snapshot.processedIdempotencyKeys,
      contains('run-11-started'),
    );
  });
}

WorkshopDurableOrchestrator _orchestrator(
  InMemoryWorkshopCheckpointStore checkpointStore,
  DateTime Function() clock,
) {
  return WorkshopDurableOrchestrator(
    store: WorkshopCheckpointDurableOrchestrationStore(
      checkpointStore: checkpointStore,
    ),
    clock: clock,
  );
}

WorkshopGitHubRun _run({
  required int id,
  required WorkshopGitHubRunStatus status,
  WorkshopGitHubRunConclusion conclusion =
      WorkshopGitHubRunConclusion.unknown,
}) {
  return WorkshopGitHubRun(
    id: id,
    status: status,
    conclusion: conclusion,
    htmlUrl: 'https://github.test/actions/runs/$id',
    name: 'Cantiere Private Android Build',
    headBranch: 'cantiere-build/test',
    headSha: '0123456789012345678901234567890123456789',
    runNumber: id,
    createdAt: DateTime.utc(2026, 9, 22, 20),
    updatedAt: DateTime.utc(2026, 9, 22, 20),
  );
}

final class _FakeGitHubGateway
    implements WorkshopDurableGitHubActionsGateway {
  int dispatchCalls = 0;
  int discoverCalls = 0;
  int getRunCalls = 0;
  int getArtifactsCalls = 0;

  WorkshopDurableGitHubDispatchOutcome dispatchOutcome =
      WorkshopDurableGitHubDispatchOutcome.accepted;
  WorkshopGitHubRun? discoveredRun;
  WorkshopGitHubRun? currentRun;
  List<WorkshopGitHubArtifact> artifacts = const <WorkshopGitHubArtifact>[];
  Future<void> Function()? onDispatch;

  @override
  Future<WorkshopDurableGitHubDispatchOutcome> dispatch({
    required WorkshopBuildRequest request,
    required String correlationId,
  }) async {
    dispatchCalls += 1;
    await onDispatch?.call();
    return dispatchOutcome;
  }

  @override
  Future<WorkshopGitHubRun?> discoverRun({
    required WorkshopBuildRequest request,
    required String correlationId,
  }) async {
    discoverCalls += 1;
    return discoveredRun;
  }

  @override
  Future<WorkshopGitHubRun?> getRun(int runId) async {
    getRunCalls += 1;
    return currentRun;
  }

  @override
  Future<List<WorkshopGitHubArtifact>> getArtifacts(int runId) async {
    getArtifactsCalls += 1;
    return artifacts;
  }
}
