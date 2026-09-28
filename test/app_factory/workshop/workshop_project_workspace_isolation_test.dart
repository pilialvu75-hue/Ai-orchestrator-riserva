import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';

WorkshopProjectPlan _plan(String id) {
  const taskId = 'task:initial-implementation';
  return WorkshopProjectPlan(
    id: id,
    title: id,
    goal: 'Generate one isolated app.',
    status: WorkshopProjectStatus.planned,
    phases: <WorkshopProjectPhase>[
      WorkshopProjectPhase(
        id: 'phase:implementation',
        title: 'Implementation',
        description: 'Implementation',
        taskIds: const <String>[taskId],
      ),
    ],
    tasks: <WorkshopProjectTask>[
      WorkshopProjectTask(
        id: taskId,
        title: 'Funzionalità principale',
        description: 'Implement the product.',
        phaseId: 'phase:implementation',
        affectedPaths: const <String>['lib/main.dart'],
      ),
    ],
  );
}

void main() {
  test('project-scoped workspaces never leak files across equal task ids',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'workshop-project-isolation-',
    );
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    final executor = WorkshopFactory.createProjectExecutor(
      workspaceRootPath: root.path,
      projectScopedWorkspaces: true,
    );

    final walking = _plan('project:walking-app');
    final walkingSession = await executor.prepareNextTask(walking);
    expect(walkingSession, isNotNull);

    final walkingRoot =
        executor.workspaceRootPathForProject(walking.id);
    expect(walkingRoot, isNotNull);
    final walkingMain = File('$walkingRoot/lib/main.dart');
    await walkingMain.parent.create(recursive: true);
    await walkingMain.writeAsString('void main() => print("walking");');
    final generatedBuildFile = File('$walkingRoot/build/generated.txt');
    await generatedBuildFile.parent.create(recursive: true);
    await generatedBuildFile.writeAsString('generated output');

    await executor.seedProjectWorkspace(
      sourceProjectId: walking.id,
      targetProjectId: 'project:walking-repair',
    );
    final repairRoot =
        executor.workspaceRootPathForProject('project:walking-repair');
    expect(repairRoot, isNotNull);
    expect(
      await File('$repairRoot/lib/main.dart').readAsString(),
      'void main() => print("walking");',
    );
    expect(
      await File('$repairRoot/build/generated.txt').exists(),
      isFalse,
    );

    final counter = _plan('project:counter-test');
    final counterSession = await executor.prepareNextTask(counter);
    expect(counterSession, isNotNull);

    final counterRoot =
        executor.workspaceRootPathForProject(counter.id);
    expect(counterRoot, isNotNull);
    expect(counterRoot, isNot(walkingRoot));
    expect(counterSession!.workspace.read('lib/main.dart'), isNull);
    expect(
      identical(
        executor.sessionForTask('task:initial-implementation'),
        counterSession,
      ),
      isTrue,
    );

    final resumedWalkingSession =
        await executor.prepareNextTask(walking);
    expect(resumedWalkingSession, isNotNull);
    expect(
      resumedWalkingSession!.workspace.read('lib/main.dart'),
      'void main() => print("walking");',
    );
    expect(
      identical(resumedWalkingSession, walkingSession),
      isFalse,
    );
  });

  test('recovery fails closed when applied source has no isolated workspace',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'workshop-project-recovery-',
    );
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    WorkshopDashboardController controller() {
      final executor = WorkshopFactory.createProjectExecutor(
        workspaceRootPath: root.path,
        projectScopedWorkspaces: true,
      );
      return WorkshopDashboardController(
        engine: WorkshopEngine(projectExecutor: executor),
      );
    }

    final original = controller();
    addTearDown(original.dispose);
    final plan = original.startProduction(
      title: 'Legacy project',
      instruction: 'Create an isolated app.',
    );
    final requestId = original.state.requestId!;
    final request = original.engine.requestOf(requestId)!;

    // Simulate a legacy checkpoint claiming applied work while no project
    // directory exists in the new isolated layout.
    plan.tasks.first.completed = true;

    final restored = controller();
    addTearDown(restored.dispose);

    await expectLater(
      restored.restoreProduction(
        request: request,
        plan: plan,
      ),
      throwsA(isA<StateError>()),
    );

    final projectRoot =
        restored.engine.projectExecutor!.workspaceRootPathForProject(plan.id)!;
    expect(await Directory(projectRoot).exists(), isFalse);
  });

}
