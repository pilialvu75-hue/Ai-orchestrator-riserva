import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_execution.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_executor.dart';

void main() {
  group('WorkshopExecutionContinuity', () {
    test('attaches authoritative checkpoint without changing execution identity',
        () {
      final execution = _execution();
      final task = _task();

      final attached = WorkshopExecutionContinuity.attachCheckpoint(
        execution: execution,
        task: task,
      );

      expect(attached.executionId, execution.executionId);
      expect(attached.attemptId, execution.attemptId);
      expect(attached.taskId, execution.taskId);
      expect(attached.checkpointId, 'checkpoint-7');
      expect(attached.resumePhase, 'review');
      expect(attached.status, WorkshopExecutionStatus.checkpointed);
    });

    test('builds provider-neutral semantic resume context from Cantiere state',
        () {
      final task = _task();
      final attached = WorkshopExecutionContinuity.attachCheckpoint(
        execution: _execution(),
        task: task,
      );

      final context = WorkshopExecutionContinuity.buildResumeContext(
        execution: attached,
        task: task,
        result: const WorkshopTaskExecutionResult(
          taskId: 'task-1',
          status: WorkshopTaskStatus.checkpointed,
          changedFiles: <String>['lib/b.dart'],
          artifacts: <String>['artifact-result'],
        ),
      );

      expect(context.executionId, 'execution-stable');
      expect(context.attemptId, 'attempt-2');
      expect(context.checkpointId, 'checkpoint-7');
      expect(context.phase, 'review');
      expect(context.objective, 'Implement the requested feature safely.');
      expect(context.constraints, contains('Do not bypass approval.'));
      expect(context.completedSteps, <String>['analysis', 'implementation']);
      expect(context.changedFiles, <String>['lib/a.dart']);
      expect(context.decisions, <String>['Keep Cantiere authoritative']);
      expect(context.verified, <String>['flutter analyze']);
      expect(context.remainingWork, <String>['review', 'validation']);
      expect(
        context.artifacts,
        containsAll(<String>['artifact-checkpoint', 'artifact-result']),
      );
      expect(context.nextStep, 'Run reviewer on the current diff.');

      final metadata = context.toMetadata();
      expect(metadata['executionId'], 'execution-stable');
      expect(metadata['attemptId'], 'attempt-2');
      expect(metadata['checkpointId'], 'checkpoint-7');
      expect(metadata['nextStep'], 'Run reviewer on the current diff.');
    });

    test('rejects an execution bound to a stale Cantiere checkpoint', () {
      final execution = _execution().copyWith(
        checkpointId: 'checkpoint-old',
        resumePhase: 'implementation',
      );

      expect(
        () => WorkshopExecutionContinuity.buildResumeContext(
          execution: execution,
          task: _task(),
        ),
        throwsStateError,
      );
    });
  });
}

WorkshopExecution _execution() {
  final startedAt = DateTime.utc(2026, 9, 7, 1);
  return WorkshopExecution(
    executionId: 'execution-stable',
    attemptId: 'attempt-2',
    projectId: 'project-1',
    taskId: 'task-1',
    sessionId: 'session-1',
    resource: WorkshopTaskResource.cloud,
    status: WorkshopExecutionStatus.running,
    startedAt: startedAt,
    updatedAt: startedAt,
    providerId: 'claude',
    modelId: 'model-a',
  );
}

WorkshopTaskContract _task() {
  final task = WorkshopTaskContract(
    id: 'task-1',
    title: 'Implement feature',
    objective: 'Implement the requested feature safely.',
    kind: WorkshopTaskKind.codeModification,
    constraints: const <String>['Do not bypass approval.'],
  );

  task.markCheckpointed(
    WorkshopTaskCheckpoint(
      id: 'checkpoint-7',
      createdAt: DateTime.utc(2026, 9, 7, 2),
      phase: 'review',
      completedSteps: const <String>['analysis', 'implementation'],
      changedFiles: const <String>['lib/a.dart'],
      metadata: const <String, dynamic>{
        'decisions': <String>['Keep Cantiere authoritative'],
        'verified': <String>['flutter analyze'],
        'remainingWork': <String>['review', 'validation'],
        'artifacts': <String>['artifact-checkpoint'],
        'nextStep': 'Run reviewer on the current diff.',
      },
    ),
  );

  return task;
}
