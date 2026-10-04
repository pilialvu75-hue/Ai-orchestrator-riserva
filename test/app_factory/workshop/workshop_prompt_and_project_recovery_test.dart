import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_persistent_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_recovery_coordinator.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('pending prompt survives a fresh recovery coordinator', () async {
    final first = WorkshopProductionRecoveryCoordinator(
      checkpointStore: PersistentWorkshopCheckpointStore(
        preferences: PreferencesService(
          await SharedPreferences.getInstance(),
        ),
      ),
    );

    await first.savePendingPrompt(
      instruction: 'Crea Manga Kids con una home semplice.',
      title: 'Manga Kids',
    );

    final reopened = WorkshopProductionRecoveryCoordinator(
      checkpointStore: PersistentWorkshopCheckpointStore(
        preferences: PreferencesService(
          await SharedPreferences.getInstance(),
        ),
      ),
    );

    final draft = await reopened.loadPendingPrompt();
    expect(draft, isNotNull);
    expect(draft!.instruction, 'Crea Manga Kids con una home semplice.');
    expect(draft.title, 'Manga Kids');

    await reopened.clearPendingPrompt();
    expect(await first.loadPendingPrompt(), isNull);
  });

  test('removeProject deletes only the selected saved project', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'workshop-project-delete-',
    );
    addTearDown(() async {
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    });

    await File('${workspace.path}/README.md').writeAsString('# fixture\n');

    final coordinator = WorkshopProductionRecoveryCoordinator(
      checkpointStore: PersistentWorkshopCheckpointStore(
        preferences: PreferencesService(
          await SharedPreferences.getInstance(),
        ),
      ),
    );
    final controller = _controllerFor(workspace.path);
    addTearDown(controller.dispose);

    controller.startProduction(
      title: 'Manga Kids',
      instruction: 'Crea Manga Kids.',
    );
    final mangaProjectId = controller.state.projectId!;
    await coordinator.saveCurrent(controller);

    controller.forgetProduction();
    controller.startProduction(
      title: 'Secondo progetto',
      instruction: 'Crea un secondo progetto.',
    );
    final secondProjectId = controller.state.projectId!;
    await coordinator.saveCurrent(controller);

    expect(await coordinator.listSavedProjects(), hasLength(2));

    await coordinator.removeProject(mangaProjectId);

    final remaining = await coordinator.listSavedProjects();
    expect(remaining, hasLength(1));
    expect(remaining.single.projectId, secondProjectId);
    expect(remaining.single.title, 'Secondo progetto');
  });
}

WorkshopDashboardController _controllerFor(String workspaceRootPath) {
  final executor = WorkshopFactory.createProjectExecutor(
    workspaceRootPath: workspaceRootPath,
  );

  return WorkshopDashboardController(
    engine: WorkshopEngine(projectExecutor: executor),
  );
}
