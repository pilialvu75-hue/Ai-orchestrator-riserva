import 'package:ai_orchestrator/app_factory/workshop/workshop_execution.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_execution_resume_attempt.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorkshopExecutionResumeAttemptCoordinator', () {
    test(
      'keeps execution identity, creates a new attempt and carries semantic checkpoint state across provider failover',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = PreferencesService(
          await SharedPreferences.getInstance(),
        );
        final store = WorkshopExecutionStore(preferences: preferences);
        final coordinator = WorkshopExecutionResumeAttemptCoordinator(
          executionStore: store,
        );

        final current = await store.create(
          projectId: 'project-1',
          taskId: 'task-1',
          sessionId: 'session-1',
          resource: WorkshopTaskResource.cloud,
          allocationId: 'allocation-claude',
          executorId: 'executor-claude',
          providerId: 'claude',
          modelId: 'claude-model',
          accountId: 'claude-account',
        );

        final task = WorkshopTaskContract(
          id: 'task-1',
          title: 'Implement feature',
          objective: 'Continue implementation safely.',
          kind: WorkshopTaskKind.codeModification,
          constraints: const <String>['Keep approval mandatory.'],
        );
        task.markCheckpointed(
          WorkshopTaskCheckpoint(
            id: 'checkpoint-9',
            createdAt: DateTime.utc(2026, 9, 7, 10),
            phase: 'implementation',
            completedSteps: const <String>['analysis', 'scaffold'],
            changedFiles: const <String>['lib/feature.dart'],
            metadata: const <String, dynamic>{
              'decisions': <String>['Keep Cantiere authoritative'],
              'verified': <String>['flutter analyze'],
              'remainingWork': <String>['finish implementation', 'review'],
              'artifacts': <String>['artifact-checkpoint'],
              'nextStep': 'Continue from the staged implementation.',
            },
          ),
        );

        final handoff = await coordinator.beginNextAttempt(
          execution: current,
          task: task,
          allocationId: 'allocation-gemini',
          executorId: 'executor-gemini',
          providerId: 'gemini',
          modelId: 'gemini-model',
          accountId: 'gemini-account',
        );

        expect(handoff.execution.executionId, current.executionId);
        expect(handoff.execution.attemptId, isNot(current.attemptId));
        expect(handoff.execution.projectId, current.projectId);
        expect(handoff.execution.taskId, current.taskId);
        expect(handoff.execution.sessionId, current.sessionId);
        expect(handoff.execution.checkpointId, 'checkpoint-9');
        expect(handoff.execution.resumePhase, 'implementation');
        expect(handoff.execution.providerId, 'gemini');
        expect(handoff.execution.modelId, 'gemini-model');
        expect(handoff.execution.accountId, 'gemini-account');
        expect(handoff.execution.executorId, 'executor-gemini');
        expect(handoff.execution.allocationId, 'allocation-gemini');
        expect(handoff.execution.status, WorkshopExecutionStatus.created);

        final resume = handoff.resumeContext;
        expect(resume.executionId, current.executionId);
        expect(resume.attemptId, handoff.execution.attemptId);
        expect(resume.checkpointId, 'checkpoint-9');
        expect(resume.phase, 'implementation');
        expect(resume.objective, 'Continue implementation safely.');
        expect(resume.constraints, <String>['Keep approval mandatory.']);
        expect(resume.completedSteps, <String>['analysis', 'scaffold']);
        expect(resume.changedFiles, <String>['lib/feature.dart']);
        expect(resume.decisions, <String>['Keep Cantiere authoritative']);
        expect(resume.verified, <String>['flutter analyze']);
        expect(
          resume.remainingWork,
          <String>['finish implementation', 'review'],
        );
        expect(resume.artifacts, contains('artifact-checkpoint'));
        expect(resume.nextStep, 'Continue from the staged implementation.');

        final stored = await store.load(current.executionId);
        expect(stored, isNotNull);
        expect(stored!.executionId, current.executionId);
        expect(stored.attemptId, handoff.execution.attemptId);
        expect(stored.providerId, 'gemini');
        expect(stored.checkpointId, 'checkpoint-9');
      },
    );

    test('rejects provider failover when Cantiere has no checkpoint', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final store = WorkshopExecutionStore(preferences: preferences);
      final coordinator = WorkshopExecutionResumeAttemptCoordinator(
        executionStore: store,
      );
      final current = await store.create(
        projectId: 'project-1',
        taskId: 'task-1',
        sessionId: 'session-1',
        resource: WorkshopTaskResource.cloud,
        providerId: 'claude',
      );
      final task = WorkshopTaskContract(
        id: 'task-1',
        title: 'Implement feature',
        objective: 'Continue implementation safely.',
        kind: WorkshopTaskKind.codeModification,
      );

      expect(
        () => coordinator.beginNextAttempt(
          execution: current,
          task: task,
          providerId: 'gemini',
        ),
        throwsStateError,
      );
    });
  });
}
