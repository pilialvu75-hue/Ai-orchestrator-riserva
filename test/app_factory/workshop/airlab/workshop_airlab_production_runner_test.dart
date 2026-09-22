import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_production_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_execution_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

void main() {
  group('WorkshopAirLabProductionTaskMapper', () {
    const mapper = WorkshopAirLabProductionTaskMapper();

    test('maps only the overlap of authoritative writable scopes', () {
      final plan = _plan(
        task: WorkshopProjectTask(
          id: 'task-a6',
          title: 'Update module',
          description: 'Implement the bounded module change.',
          phaseId: 'phase-a6',
          affectedPaths: const <String>[
            'lib/a.dart',
            'lib/b.dart',
          ],
          validationCriteria: const <String>[
            'Unit tests pass',
            'Static analysis passes',
          ],
        ),
      );
      const request = WorkshopRequest(
        id: 'request-a6',
        title: 'Update module',
        instruction: 'Implement safely.',
        operation: WorkshopOperation.modify,
        targetFiles: <String>[
          'lib/a.dart',
          'lib/c.dart',
        ],
        constraints: <String>['Preserve public API.'],
      );

      final task = mapper.map(
        plan: plan,
        projectTask: plan.tasks.single,
        request: request,
      );

      expect(task.fileScope.allowed, <String>['lib/a.dart']);
      expect(task.isAgentReady, isTrue);
      expect(task.metadata['productionProjectId'], plan.id);
      expect(task.metadata['productionRequestId'], request.id);
      expect(task.acceptanceCriteria, hasLength(2));
      expect(
        task.constraints,
        contains('Do not modify files outside the explicit AIrLab production scope.'),
      );
    });

    test('uses request scope when project task has no affected paths', () {
      final plan = _plan(
        task: WorkshopProjectTask(
          id: 'task-request-scope',
          title: 'Update request target',
          description: 'Change only the explicit request target.',
          phaseId: 'phase-a6',
          validationCriteria: const <String>['Tests pass'],
        ),
      );
      const request = WorkshopRequest(
        id: 'request-scope',
        title: 'Update request target',
        instruction: 'Change the file.',
        operation: WorkshopOperation.modify,
        targetFiles: <String>['lib/request.dart'],
      );

      final task = mapper.map(
        plan: plan,
        projectTask: plan.tasks.single,
        request: request,
      );

      expect(task.fileScope.allowed, <String>['lib/request.dart']);
    });

    test('fails closed when task and request scopes disagree', () {
      final plan = _plan(
        task: WorkshopProjectTask(
          id: 'task-mismatch',
          title: 'Mismatch',
          description: 'Mismatch.',
          phaseId: 'phase-a6',
          affectedPaths: const <String>['lib/a.dart'],
          validationCriteria: const <String>['Tests pass'],
        ),
      );
      const request = WorkshopRequest(
        id: 'request-mismatch',
        title: 'Mismatch',
        instruction: 'Mismatch.',
        operation: WorkshopOperation.modify,
        targetFiles: <String>['lib/b.dart'],
      );

      expect(
        () => mapper.map(
          plan: plan,
          projectTask: plan.tasks.single,
          request: request,
        ),
        throwsStateError,
      );
    });

    test('fails closed outside software domain', () {
      final task = WorkshopProjectTask(
        id: 'task-hardware',
        title: 'Hardware',
        description: 'Hardware task.',
        phaseId: 'phase-a6',
        affectedPaths: const <String>['hardware/**'],
        validationCriteria: const <String>['Validation passes'],
      );
      final plan = WorkshopProjectPlan(
        id: 'project-hardware',
        title: 'Hardware',
        goal: 'Hardware',
        domain: WorkshopProjectDomain.embedded,
        phases: <WorkshopProjectPhase>[
          WorkshopProjectPhase(
            id: 'phase-a6',
            title: 'A6',
            description: 'A6',
            taskIds: <String>[task.id],
          ),
        ],
        tasks: <WorkshopProjectTask>[task],
      );
      const request = WorkshopRequest(
        id: 'request-hardware',
        title: 'Hardware',
        instruction: 'Hardware',
        targetFiles: <String>['hardware/**'],
      );

      expect(
        () => mapper.map(
          plan: plan,
          projectTask: task,
          request: request,
        ),
        throwsStateError,
      );
    });
  });

  group('WorkshopAirLabProductionRunnerSelector', () {
    test('disabled selection returns exact historical runner instance', () {
      final historical = _NeverRunProductionRunner();

      final selected = WorkshopAirLabProductionRunnerSelector.select(
        enabled: false,
        historicalRunner: historical,
      );

      expect(identical(selected, historical), isTrue);
    });

    test('enabled selection fails closed without explicit A6 runner', () {
      final historical = _NeverRunProductionRunner();

      expect(
        () => WorkshopAirLabProductionRunnerSelector.select(
          enabled: true,
          historicalRunner: historical,
        ),
        throwsStateError,
      );
    });
  });
}

WorkshopProjectPlan _plan({
  required WorkshopProjectTask task,
}) {
  return WorkshopProjectPlan(
    id: 'project-a6',
    title: 'A6 project',
    goal: 'Implement one bounded software change.',
    domain: WorkshopProjectDomain.software,
    status: WorkshopProjectStatus.inProgress,
    requirements: const <String>['Keep the change reviewable.'],
    constraints: const <String>['Preserve existing behavior.'],
    validationCriteria: const <String>['Project validation passes'],
    phases: <WorkshopProjectPhase>[
      WorkshopProjectPhase(
        id: 'phase-a6',
        title: 'A6',
        description: 'A6',
        taskIds: <String>[task.id],
      ),
    ],
    tasks: <WorkshopProjectTask>[task],
  );
}

final class _NeverRunProductionRunner
    implements WorkshopProductionExecutionRunner {
  @override
  WorkshopProductionTaskHandle preparedHandle() {
    throw StateError('not used');
  }

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) {
    throw StateError('not used');
  }
}
