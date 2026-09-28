import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
}
