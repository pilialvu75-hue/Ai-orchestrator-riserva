import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_persistent_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_recovery_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    workspace = await Directory.systemTemp.createTemp(
      'workshop-production-recovery-',
    );
    await File('${workspace.path}/README.md').writeAsString(
      '# Recovery fixture\n',
    );
  });

  tearDown(() async {
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  test(
    'reopens the same active task from the persistent Workshop checkpoint',
    () async {
      final firstPreferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final firstCoordinator = WorkshopProductionRecoveryCoordinator(
        checkpointStore: PersistentWorkshopCheckpointStore(
          preferences: firstPreferences,
        ),
      );
      final firstController = _controllerFor(workspace.path);

      firstCoordinator.attach(firstController);

      firstController.startProduction(
        title: 'Recoverable Cantiere project',
        instruction: 'Create the requested application safely.',
        requirements: const <String>['Keep the existing workspace intact.'],
        technologies: const <String>['Flutter'],
      );

      final originalRequestId = firstController.state.requestId;
      final originalProjectId = firstController.state.projectId;

      final prepared = await firstController.prepareNextTask();
      expect(prepared, isNotNull);
      expect(
        firstController.state.activeTaskId,
        'task:initial-implementation',
      );

      await firstCoordinator.detach();
      firstController.dispose();

      // Simulate reopening the app/Cantiere with a new composition while the
      // same SharedPreferences backing store and real workspace survive.
      final secondPreferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final secondCoordinator = WorkshopProductionRecoveryCoordinator(
        checkpointStore: PersistentWorkshopCheckpointStore(
          preferences: secondPreferences,
        ),
      );
      final secondController = _controllerFor(workspace.path);

      final restored = await secondCoordinator.restore(secondController);

      expect(restored, isTrue);
      expect(secondController.state.requestId, originalRequestId);
      expect(secondController.state.projectId, originalProjectId);
      expect(
        secondController.state.activeTaskId,
        'task:initial-implementation',
      );
      expect(secondController.state.stage, WorkshopStage.implementation);
      expect(secondController.state.completedTasks, 0);
      expect(secondController.state.totalTasks, 1);

      final restoredPlan = secondController.engine.planOf(originalRequestId!);
      expect(restoredPlan, isNotNull);
      expect(restoredPlan!.title, 'Recoverable Cantiere project');
      expect(
        restoredPlan.goal,
        'Create the requested application safely.',
      );
      expect(
        restoredPlan.requirements,
        const <String>['Keep the existing workspace intact.'],
      );
      expect(restoredPlan.technologies, const <String>['Flutter']);

      // Recovery deliberately creates a fresh guarded WorkspaceSession. No
      // staged diff or owner approval is fabricated after process death.
      expect(
        secondController.engine.stageOf(originalRequestId),
        WorkshopStage.implementation,
      );

      secondController.dispose();
    },
  );

  test(
    'keeps a completed project build-ready after a restart',
    () async {
      final preferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final firstCoordinator = WorkshopProductionRecoveryCoordinator(
        checkpointStore: PersistentWorkshopCheckpointStore(
          preferences: preferences,
        ),
      );
      final firstController = _controllerFor(workspace.path);

      firstController.startProduction(
        title: 'Completed Cantiere project',
        instruction: 'Produce the final Android application.',
      );

      final requestId = firstController.state.requestId!;
      final plan = firstController.engine.planOf(requestId)!;
      final task = plan.taskById('task:initial-implementation')!;
      final phase = plan.phaseById('phase:implementation')!;

      // This test fixture represents the authoritative state that normally
      // results only after the guarded approval/apply lifecycle succeeds.
      task.completed = true;
      phase.status = WorkshopProjectPhaseStatus.completed;
      plan.status = WorkshopProjectStatus.completed;

      await firstCoordinator.saveCurrent(firstController);
      firstController.dispose();

      final secondCoordinator = WorkshopProductionRecoveryCoordinator(
        checkpointStore: PersistentWorkshopCheckpointStore(
          preferences: PreferencesService(
            await SharedPreferences.getInstance(),
          ),
        ),
      );
      final secondController = _controllerFor(workspace.path);

      final restored = await secondCoordinator.restore(secondController);

      expect(restored, isTrue);
      expect(secondController.state.requestId, requestId);
      expect(
        secondController.state.projectStatus,
        WorkshopProjectStatus.completed,
      );
      expect(secondController.state.stage, WorkshopStage.completed);
      expect(secondController.state.activeTaskId, isNull);
      expect(secondController.state.completedTasks, 1);
      expect(secondController.state.totalTasks, 1);
      expect(secondController.state.progress, 1);

      final restoredPlan = secondController.engine.planOf(requestId)!;
      expect(restoredPlan.isComplete, isTrue);
      expect(restoredPlan.tasks.every((item) => item.completed), isTrue);

      secondController.dispose();
    },
  );
}

WorkshopDashboardController _controllerFor(String workspaceRootPath) {
  final executor = WorkshopFactory.createProjectExecutor(
    workspaceRootPath: workspaceRootPath,
  );

  return WorkshopDashboardController(
    engine: WorkshopEngine(
      projectExecutor: executor,
    ),
  );
}
