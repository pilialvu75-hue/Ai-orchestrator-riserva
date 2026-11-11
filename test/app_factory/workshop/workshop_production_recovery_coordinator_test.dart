import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_background_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_persistent_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
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

      const approvedProposal =
          'Proposta approvata: app Flutter con contatore, +, - e Reset.';

      firstController.startProduction(
        title: 'Recoverable Cantiere project',
        instruction: 'Create the requested application safely.',
        requirements: const <String>['Keep the existing workspace intact.'],
        technologies: const <String>['Flutter'],
        workspaceProjectId: 'project:physical-source',
        context: <String>[
          WorkshopPreflightInferencePipeline.approvedProposalContextEntry(
            approvedProposal,
          ),
        ],
      );
      final approval = firstController.approveCurrentProject(
        derivedFromApprovalId: 'approval:root-project:42',
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
      expect(secondController.state.totalTasks, 2);
      expect(secondController.state.isProjectApproved, isTrue);
      expect(
        secondController.state.projectApproval?.approvalId,
        approval.approvalId,
      );
      expect(
        secondController.state.projectApproval?.derivedFromApprovalId,
        'approval:root-project:42',
      );

      final restoredRequest =
          secondController.engine.requestOf(originalRequestId!);
      expect(restoredRequest, isNotNull);
      expect(
        restoredRequest!.context,
        contains(
          WorkshopPreflightInferencePipeline.approvedProposalContextEntry(
            approvedProposal,
          ),
        ),
      );

      final restoredPlan = secondController.engine.planOf(originalRequestId);
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
      expect(
        restoredPlan.workspaceProjectId,
        'project:physical-source',
      );
      expect(
        restoredPlan.effectiveWorkspaceProjectId,
        'project:physical-source',
      );

      // Recovery deliberately creates a fresh guarded WorkspaceSession. No
      // staged diff or task-level apply approval is fabricated after process
      // death. The already-explicit project-level authorization is preserved.
      expect(
        secondController.engine.stageOf(originalRequestId),
        WorkshopStage.implementation,
      );

      secondController.dispose();
    },
  );

  test(
    'resumes the next incomplete bounded task after a restart',
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
        title: 'Incremental Cantiere project',
        instruction: 'Create a small counter application.',
      );

      final requestId = firstController.state.requestId!;
      final plan = firstController.engine.planOf(requestId)!;
      plan.taskById('task:initial-implementation')!.completed = true;
      plan.phaseById('phase:implementation')!.status =
          WorkshopProjectPhaseStatus.inProgress;
      plan.status = WorkshopProjectStatus.inProgress;

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
      expect(secondController.state.completedTasks, 1);
      expect(secondController.state.totalTasks, 2);
      expect(secondController.state.progress, closeTo(1 / 2, 0.0001));
      expect(
        secondController.state.activeTaskId,
        'task:acceptance-verification',
      );
      expect(secondController.state.stage, WorkshopStage.implementation);
      expect(
        secondController.engine.planOf(requestId)!.nextAvailableTask?.id,
        'task:acceptance-verification',
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
      final phase = plan.phaseById('phase:implementation')!;

      // This test fixture represents the authoritative state that normally
      // results only after every guarded approval/apply lifecycle succeeds.
      for (final task in plan.tasks) {
        task.completed = true;
      }
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
      expect(secondController.engine.stageOf(requestId), WorkshopStage.completed);
      expect(secondController.state.activeTaskId, isNull);
      expect(secondController.state.completedTasks, 2);
      expect(secondController.state.totalTasks, 2);
      expect(secondController.state.progress, 1);

      final restoredPlan = secondController.engine.planOf(requestId)!;
      expect(restoredPlan.isComplete, isTrue);
      expect(restoredPlan.tasks.every((item) => item.completed), isTrue);

      secondController.dispose();
    },
  );

  test(
    'parks multiple projects and keeps them recoverable from a neutral Cantiere',
    () async {
      final preferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final coordinator = WorkshopProductionRecoveryCoordinator(
        checkpointStore: PersistentWorkshopCheckpointStore(
          preferences: preferences,
        ),
      );
      final controller = _controllerFor(workspace.path);

      controller.startProduction(
        title: 'Progetto Alpha',
        instruction: 'Build alpha safely.',
      );
      final alphaProjectId = controller.state.projectId!;
      await coordinator.saveCurrent(controller);

      controller.forgetProduction();
      await coordinator.saveCurrent(controller);

      controller.startProduction(
        title: 'Progetto Beta',
        instruction: 'Build beta safely.',
      );
      final betaProjectId = controller.state.projectId!;
      expect(betaProjectId, isNot(alphaProjectId));
      await coordinator.saveCurrent(controller);

      controller.forgetProduction();
      await coordinator.saveCurrent(controller);

      final parked = await coordinator.listSavedProjects();
      expect(parked, hasLength(2));
      expect(
        parked.map((item) => item.projectId),
        containsAll(<String>[alphaProjectId, betaProjectId]),
      );
      expect(
        parked.map((item) => item.title),
        containsAll(<String>['Progetto Alpha', 'Progetto Beta']),
      );

      final restoredController = _controllerFor(workspace.path);
      final restored = await coordinator.restoreProject(
        restoredController,
        projectId: alphaProjectId,
      );

      expect(restored, isTrue);
      expect(restoredController.state.projectId, alphaProjectId);
      expect(restoredController.state.projectTitle, 'Progetto Alpha');

      final stillParked = await coordinator.listSavedProjects();
      expect(stillParked, hasLength(2));

      restoredController.dispose();
      controller.dispose();
    },
  );


  test(
    'saved project blocks silent model-assignment drift on restore',
    () async {
      final preferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final qwenAssignments =
          List<WorkshopModelAssignment>.of(WorkshopModelAssignments.androidDefaults);
      final firstCoordinator = WorkshopProductionRecoveryCoordinator(
        checkpointStore: PersistentWorkshopCheckpointStore(
          preferences: preferences,
        ),
        modelAssignmentsProvider: () => qwenAssignments,
      );
      final firstController = _controllerFor(workspace.path);

      firstController.startProduction(
        title: 'Bound models project',
        instruction: 'Create a small Flutter app.',
      );
      final projectId = firstController.state.projectId!;
      await firstCoordinator.saveCurrent(firstController);
      firstController.dispose();

      final driftedAssignments = WorkshopModelAssignments.withAssignment(
        qwenAssignments,
        AppAiRole.engineer,
        'nvidia/nemotron-3-ultra-550b-a55b',
      );
      final secondCoordinator = WorkshopProductionRecoveryCoordinator(
        checkpointStore: PersistentWorkshopCheckpointStore(
          preferences: PreferencesService(
            await SharedPreferences.getInstance(),
          ),
        ),
        modelAssignmentsProvider: () => driftedAssignments,
      );
      final secondController = _controllerFor(workspace.path);

      await expectLater(
        secondCoordinator.restoreProject(
          secondController,
          projectId: projectId,
        ),
        throwsA(isA<WorkshopModelAssignmentMismatch>()),
      );
      expect(secondController.state.hasProject, isFalse);
      secondController.dispose();

      final matchingCoordinator = WorkshopProductionRecoveryCoordinator(
        checkpointStore: PersistentWorkshopCheckpointStore(
          preferences: PreferencesService(
            await SharedPreferences.getInstance(),
          ),
        ),
        modelAssignmentsProvider: () => qwenAssignments,
      );
      final matchingController = _controllerFor(workspace.path);
      expect(
        await matchingCoordinator.restoreProject(
          matchingController,
          projectId: projectId,
        ),
        isTrue,
      );
      expect(matchingController.state.projectId, projectId);
      matchingController.dispose();
    },
  );

  test(
    'legacy project requires one explicit model binding before migration',
    () async {
      final preferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final legacyCoordinator = WorkshopProductionRecoveryCoordinator(
        checkpointStore: PersistentWorkshopCheckpointStore(
          preferences: preferences,
        ),
      );
      final legacyController = _controllerFor(workspace.path);
      legacyController.startProduction(
        title: 'Legacy unbound project',
        instruction: 'Create a simple Flutter app.',
      );
      final projectId = legacyController.state.projectId!;
      await legacyCoordinator.saveCurrent(legacyController);
      legacyController.dispose();

      final assignments =
          List<WorkshopModelAssignment>.of(WorkshopModelAssignments.androidDefaults);
      final bindingCoordinator = WorkshopProductionRecoveryCoordinator(
        checkpointStore: PersistentWorkshopCheckpointStore(
          preferences: PreferencesService(
            await SharedPreferences.getInstance(),
          ),
        ),
        modelAssignmentsProvider: () => assignments,
      );
      final bindingController = _controllerFor(workspace.path);

      await expectLater(
        bindingCoordinator.restoreProject(
          bindingController,
          projectId: projectId,
        ),
        throwsA(isA<WorkshopLegacyModelBindingRequired>()),
      );
      expect(bindingController.state.hasProject, isFalse);

      expect(
        await bindingCoordinator.restoreProject(
          bindingController,
          projectId: projectId,
          bindLegacyAssignments: true,
        ),
        isTrue,
      );
      bindingController.dispose();

      final restoredAgain = WorkshopProductionRecoveryCoordinator(
        checkpointStore: PersistentWorkshopCheckpointStore(
          preferences: PreferencesService(
            await SharedPreferences.getInstance(),
          ),
        ),
        modelAssignmentsProvider: () => assignments,
      );
      final restoredController = _controllerFor(workspace.path);
      expect(
        await restoredAgain.restoreProject(
          restoredController,
          projectId: projectId,
        ),
        isTrue,
      );
      restoredController.dispose();
    },
  );

  test(
    'serializes concurrent explicit checkpoint saves without losing projects',
    () async {
      final store = _BlockingWorkshopCheckpointStore();
      final coordinator = WorkshopProductionRecoveryCoordinator(
        checkpointStore: store,
      );
      final controller = _controllerFor(workspace.path);

      controller.startProduction(
        title: 'Concurrent Alpha',
        instruction: 'Persist alpha safely.',
      );
      final alphaProjectId = controller.state.projectId!;
      final alphaSave = coordinator.saveCurrent(controller);

      await store.firstSaveStarted.future;

      controller.forgetProduction();
      controller.startProduction(
        title: 'Concurrent Beta',
        instruction: 'Persist beta safely.',
      );
      final betaProjectId = controller.state.projectId!;
      final betaSave = coordinator.saveCurrent(controller);

      await Future<void>.delayed(Duration.zero);
      expect(store.maxConcurrentSaves, 1);

      store.releaseFirstSave.complete();
      await Future.wait(<Future<void>>[alphaSave, betaSave]);

      final parked = await coordinator.listSavedProjects();
      expect(parked, hasLength(2));
      expect(
        parked.map((item) => item.projectId),
        containsAll(<String>[alphaProjectId, betaProjectId]),
      );

      controller.dispose();
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


final class _BlockingWorkshopCheckpointStore
    implements WorkshopCheckpointStore {
  final Map<String, WorkshopBackgroundCheckpoint> _items =
      <String, WorkshopBackgroundCheckpoint>{};

  final Completer<void> firstSaveStarted = Completer<void>();
  final Completer<void> releaseFirstSave = Completer<void>();

  bool _blockedFirstSave = false;
  int _activeSaves = 0;
  int maxConcurrentSaves = 0;

  @override
  Future<void> save(WorkshopBackgroundCheckpoint checkpoint) async {
    _activeSaves += 1;
    if (_activeSaves > maxConcurrentSaves) {
      maxConcurrentSaves = _activeSaves;
    }

    try {
      if (!_blockedFirstSave) {
        _blockedFirstSave = true;
        firstSaveStarted.complete();
        await releaseFirstSave.future;
      }
      _items[checkpoint.jobId] = checkpoint;
    } finally {
      _activeSaves -= 1;
    }
  }

  @override
  Future<WorkshopBackgroundCheckpoint?> load(String jobId) async =>
      _items[jobId];

  @override
  Future<List<WorkshopBackgroundCheckpoint>> loadAll() async =>
      List<WorkshopBackgroundCheckpoint>.unmodifiable(_items.values);

  @override
  Future<void> remove(String jobId) async {
    _items.remove(jobId);
  }
}
