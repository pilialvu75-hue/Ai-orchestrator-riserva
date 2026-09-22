import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_background_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';

void main() {
  group('WorkshopDurableOrchestrator', () {
    late DateTime now;
    late InMemoryWorkshopCheckpointStore checkpointStore;
    late WorkshopCheckpointDurableOrchestrationStore durableStore;
    late WorkshopDurableOrchestrator orchestrator;

    setUp(() {
      now = DateTime.utc(2026, 9, 22, 8);
      checkpointStore = InMemoryWorkshopCheckpointStore();
      durableStore = WorkshopCheckpointDurableOrchestrationStore(
        checkpointStore: checkpointStore,
      );
      orchestrator = WorkshopDurableOrchestrator(
        store: durableStore,
        clock: () => now,
      );
    });

    WorkshopDurableTask task(
      String id, {
      List<String> dependencies = const <String>[],
      String capability = 'llm.coding',
      WorkshopDurableRetryPolicy retryPolicy =
          const WorkshopDurableRetryPolicy(),
      Duration timeout = const Duration(minutes: 30),
    }) {
      return WorkshopDurableTask(
        taskId: id,
        dependencies: dependencies,
        capability: capability,
        state: WorkshopDurableState.created,
        retryPolicy: retryPolicy,
        timeout: timeout,
        completionCriterionIds: <String>[id + '.done'],
        updatedAt: now,
      );
    }

    test('persists state and resumes through a new orchestrator instance',
        () async {
      await orchestrator.createProject(
        projectId: 'project-1',
        correlationId: 'corr-1',
        tasks: <WorkshopDurableTask>[task('generate')],
      );
      await orchestrator.markProjectReady('project-1');
      await orchestrator.startTask(
        projectId: 'project-1',
        taskId: 'generate',
        operationIdempotencyKey: 'generate-attempt-1',
      );

      now = now.add(const Duration(minutes: 5));

      final restarted = WorkshopDurableOrchestrator(
        store: WorkshopCheckpointDurableOrchestrationStore(
          checkpointStore: checkpointStore,
        ),
        clock: () => now,
      );
      final restored = await restarted.loadProject('project-1');

      expect(restored, isNotNull);
      expect(
        restored!.tasks['generate']!.state,
        WorkshopDurableState.running,
      );
      expect(restored.tasks['generate']!.attemptsStarted, 1);
      expect(
        restored.claimedOperationKeys,
        contains('generate-attempt-1'),
      );
      expect(
        restored.transitions.every(
          (transition) =>
              transition.reason.isNotEmpty &&
              transition.projectId == 'project-1' &&
              transition.correlationId == 'corr-1' &&
              transition.taskId.isNotEmpty,
        ),
        isTrue,
      );
    });

    test('parks CI as WAITING_EXTERNAL and exposes independent runnable work',
        () async {
      await orchestrator.createProject(
        projectId: 'project-2',
        correlationId: 'corr-2',
        tasks: <WorkshopDurableTask>[
          task('generate'),
          task(
            'ci',
            dependencies: const <String>['generate'],
            capability: 'build.android',
          ),
          task(
            'docs',
            dependencies: const <String>['generate'],
            capability: 'research.search',
          ),
          task(
            'validate',
            dependencies: const <String>['ci'],
            capability: 'artifact.validate',
          ),
        ],
      );
      await orchestrator.markProjectReady('project-2');

      await orchestrator.startTask(
        projectId: 'project-2',
        taskId: 'generate',
      );
      await orchestrator.completeTask(
        projectId: 'project-2',
        taskId: 'generate',
      );

      expect(
        (await orchestrator.runnableTasks('project-2'))
            .map((item) => item.taskId),
        containsAll(<String>['ci', 'docs']),
      );

      await orchestrator.startTask(
        projectId: 'project-2',
        taskId: 'ci',
        operationIdempotencyKey: 'ci-run-44001',
      );
      await orchestrator.waitForExternal(
        projectId: 'project-2',
        taskId: 'ci',
        wait: WorkshopDurableExternalWait(
          eventType: WorkshopDurableEventTypes.ciCompleted,
          externalId: 'run-44001',
          startedAt: now,
          timeoutAt: now.add(const Duration(hours: 1)),
        ),
        reason: WorkshopDurableEventTypes.ciStarted,
      );

      final runnableWhileCiRuns =
          await orchestrator.runnableTasks('project-2');
      expect(
        runnableWhileCiRuns.map((item) => item.taskId),
        contains('docs'),
      );

      final parked = await orchestrator.loadProject('project-2');
      expect(
        parked!.tasks['ci']!.state,
        WorkshopDurableState.waitingExternal,
      );
      expect(
        parked.state,
        WorkshopDurableState.ready,
        reason: 'Independent runnable work must prevent a global external wait.',
      );
    });

    test('CI event resumes once and duplicate delivery is idempotent',
        () async {
      await orchestrator.createProject(
        projectId: 'project-3',
        correlationId: 'corr-3',
        tasks: <WorkshopDurableTask>[
          task('ci', capability: 'build.android'),
        ],
      );
      await orchestrator.markProjectReady('project-3');
      await orchestrator.startTask(
        projectId: 'project-3',
        taskId: 'ci',
        operationIdempotencyKey: 'ci-start-3',
      );
      await orchestrator.waitForExternal(
        projectId: 'project-3',
        taskId: 'ci',
        wait: WorkshopDurableExternalWait(
          eventType: WorkshopDurableEventTypes.ciCompleted,
          externalId: 'run-3',
          startedAt: now,
        ),
      );

      final event = WorkshopDurableExternalEvent(
        type: WorkshopDurableEventTypes.ciCompleted,
        projectId: 'project-3',
        taskId: 'ci',
        correlationId: 'corr-3',
        idempotencyKey: 'github-actions:run-3:completed',
        occurredAt: now.add(const Duration(minutes: 18)),
        success: true,
        externalId: 'run-3',
        artifactIds: const <String>['artifact-3'],
      );

      final first = await orchestrator.handleExternalEvent(event);
      final transitionCount = first.snapshot.transitions.length;
      expect(first.duplicate, isFalse);
      expect(first.matchedTask, isTrue);
      expect(
        first.snapshot.tasks['ci']!.state,
        WorkshopDurableState.validating,
      );
      expect(
        first.snapshot.tasks['ci']!.artifactIds,
        contains('artifact-3'),
      );

      final duplicate = await orchestrator.handleExternalEvent(event);
      expect(duplicate.duplicate, isTrue);
      expect(duplicate.matchedTask, isFalse);
      expect(duplicate.snapshot.transitions.length, transitionCount);

      await orchestrator.validationPassed(
        projectId: 'project-3',
        taskId: 'ci',
      );
      final completed = await orchestrator.loadProject('project-3');
      expect(completed!.state, WorkshopDurableState.completed);
    });

    test('retry policy distinguishes retryable and terminal failures',
        () async {
      await orchestrator.createProject(
        projectId: 'project-4',
        correlationId: 'corr-4',
        tasks: <WorkshopDurableTask>[
          task(
            'provider-call',
            retryPolicy: const WorkshopDurableRetryPolicy(
              maxAttempts: 3,
              retryableFailures: <WorkshopDurableFailureClass>{
                WorkshopDurableFailureClass.networkError,
                WorkshopDurableFailureClass.rateLimit,
                WorkshopDurableFailureClass.providerUnavailable,
              },
            ),
          ),
        ],
      );
      await orchestrator.markProjectReady('project-4');
      await orchestrator.startTask(
        projectId: 'project-4',
        taskId: 'provider-call',
      );

      final retrying = await orchestrator.failTask(
        projectId: 'project-4',
        taskId: 'provider-call',
        failureClass: WorkshopDurableFailureClass.networkError,
      );
      expect(
        retrying.tasks['provider-call']!.state,
        WorkshopDurableState.retrying,
      );
      expect(
        (await orchestrator.runnableTasks('project-4')).single.taskId,
        'provider-call',
      );

      await orchestrator.startTask(
        projectId: 'project-4',
        taskId: 'provider-call',
      );
      final failed = await orchestrator.failTask(
        projectId: 'project-4',
        taskId: 'provider-call',
        failureClass: WorkshopDurableFailureClass.invalidArtifact,
      );

      expect(
        failed.tasks['provider-call']!.state,
        WorkshopDurableState.failed,
      );
      expect(failed.state, WorkshopDurableState.failed);
    });

    test('watchdog detects stale work and already available external events',
        () async {
      await orchestrator.createProject(
        projectId: 'project-5',
        correlationId: 'corr-5',
        tasks: <WorkshopDurableTask>[
          task(
            'stale',
            timeout: const Duration(minutes: 1),
          ),
          task('ci', capability: 'build.windows'),
        ],
      );
      await orchestrator.markProjectReady('project-5');
      await orchestrator.startTask(
        projectId: 'project-5',
        taskId: 'stale',
      );
      await orchestrator.startTask(
        projectId: 'project-5',
        taskId: 'ci',
      );
      await orchestrator.waitForExternal(
        projectId: 'project-5',
        taskId: 'ci',
        wait: WorkshopDurableExternalWait(
          eventType: WorkshopDurableEventTypes.ciCompleted,
          externalId: 'run-5',
          startedAt: now,
          timeoutAt: now.add(const Duration(hours: 1)),
        ),
      );

      now = now.add(const Duration(minutes: 2));
      final observed = WorkshopDurableExternalEvent(
        type: WorkshopDurableEventTypes.ciCompleted,
        projectId: 'project-5',
        taskId: 'ci',
        correlationId: 'corr-5',
        idempotencyKey: 'run-5-completed',
        occurredAt: now,
        success: true,
        externalId: 'run-5',
      );

      final findings = await orchestrator.watchdogScan(
        'project-5',
        observedEvents: <WorkshopDurableExternalEvent>[observed],
      );

      expect(
        findings.map((item) => item.type),
        contains(WorkshopDurableWatchdogFindingType.staleRunning),
      );
      expect(
        findings.map((item) => item.type),
        contains(WorkshopDurableWatchdogFindingType.externalEventAvailable),
      );

      final reconciled =
          await orchestrator.reconcileObservedEvents(<WorkshopDurableExternalEvent>[
        observed,
      ]);
      expect(reconciled.single.matchedTask, isTrue);
      expect(
        reconciled.single.snapshot.tasks['ci']!.state,
        WorkshopDurableState.validating,
      );
    });

    test('operation idempotency prevents a duplicate external start',
        () async {
      await orchestrator.createProject(
        projectId: 'project-6',
        correlationId: 'corr-6',
        tasks: <WorkshopDurableTask>[task('build', capability: 'build.web')],
      );
      await orchestrator.markProjectReady('project-6');

      final firstClaim = await orchestrator.claimOperation(
        projectId: 'project-6',
        idempotencyKey: 'build:web:project-6',
      );
      final duplicateClaim = await orchestrator.claimOperation(
        projectId: 'project-6',
        idempotencyKey: 'build:web:project-6',
      );

      expect(firstClaim, isTrue);
      expect(duplicateClaim, isFalse);
    });
  });
}
