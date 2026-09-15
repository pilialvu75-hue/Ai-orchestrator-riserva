import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_provider_policy.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_read_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_reuse_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_multi_role_pipeline_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_lifecycle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_capture_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_source_snapshot.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_source_snapshot_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_source_snapshot_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_approval_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';

final class WorkshopProductionLifecycleBundle {
  const WorkshopProductionLifecycleBundle({
    required this.dashboardController,
    required this.preflight,
    required this.taskLifecycle,
    required this.projectExecutor,
    this.reuseLibrary,
    this.reuseSourceSnapshots,
    this.reuseCaptureService = const WorkshopReuseCaptureService(),
    this.reuseSourceSnapshotService =
        const WorkshopReuseSourceSnapshotService(),
    this.libraryReuseService,
    this.onReuseLibraryChanged,
    this.onReuseSourceSnapshotsChanged,
    this.reuseSnapshotsRootPath,
    this.workspaceRootPath,
  });

  final WorkshopDashboardController dashboardController;
  final WorkshopPreflightInferencePipeline preflight;
  final WorkshopPreparedTaskLifecycle taskLifecycle;
  final WorkshopReuseLibrary? reuseLibrary;
  final WorkshopReuseSourceSnapshotIndex? reuseSourceSnapshots;
  final WorkshopReuseCaptureService reuseCaptureService;
  final WorkshopReuseSourceSnapshotService reuseSourceSnapshotService;
  final WorkshopLibraryReuseService? libraryReuseService;
  final Future<void> Function(WorkshopReuseLibrary)? onReuseLibraryChanged;
  final Future<void> Function(WorkshopReuseSourceSnapshotIndex)?
      onReuseSourceSnapshotsChanged;
  final String? reuseSnapshotsRootPath;
  final WorkshopProjectExecutor projectExecutor;
  final String? workspaceRootPath;
}

abstract final class WorkshopProductionLifecycleBundleFactory {
  static WorkshopProductionLifecycleBundle create({
    required WorkshopProjectExecutor projectExecutor,
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    Map<AppAiRole, WorkshopInferenceGateway>? roleGateways,
    WorkshopBuildLab? buildLab,
    WorkshopReuseLibrary? reuseLibrary,
    Future<void> Function(WorkshopReuseLibrary)? onReuseLibraryChanged,
    WorkshopReuseSourceSnapshotIndex? reuseSourceSnapshots,
    WorkshopReuseCaptureService reuseCaptureService =
        const WorkshopReuseCaptureService(),
    WorkshopReuseSourceSnapshotService reuseSourceSnapshotService =
        const WorkshopReuseSourceSnapshotService(),
    WorkshopLibraryReuseService? libraryReuseService,
    WorkshopWebResearchService? webResearchService,
    Future<void> Function(WorkshopReuseSourceSnapshotIndex)?
        onReuseSourceSnapshotsChanged,
    String? reuseSnapshotsRootPath,
    String? workspaceRootPath,
  }) {
    final orchestratorGateway = roleGateways?[AppAiRole.workshopOrchestrator];
    final engine = WorkshopFactory.createEngine(
      projectExecutor: projectExecutor,
      inferenceService: inferenceService,
      inferenceGateway: orchestratorGateway,
      role: AppAiRole.workshopOrchestrator,
      assignments: assignments,
    );
    final stageInference = WorkshopMultiRolePipelineFactory.createStageInference(
      inferenceService: inferenceService,
      assignments: assignments,
      gateways: roleGateways,
    );
    final preflight = WorkshopPreflightInferencePipeline(
      inference: stageInference,
      reuseLibrary: reuseLibrary,
      webResearchService: webResearchService,
      onReuseLibraryChanged: onReuseLibraryChanged,
    );
    final inferenceRunner =
        WorkshopMultiRolePipelineFactory.createPreparedTaskRunner(
      executor: projectExecutor,
      stageInference: stageInference,
    );
    final lifecycle = WorkshopPreparedTaskLifecycle(
      inferenceRunner: inferenceRunner,
      approvalController: WorkshopTaskApprovalController(
        executor: projectExecutor,
      ),
    );

    return WorkshopProductionLifecycleBundle(
      dashboardController: WorkshopDashboardController(
        engine: engine,
        buildLab: buildLab,
      ),
      preflight: preflight,
      taskLifecycle: lifecycle,
      projectExecutor: projectExecutor,
      reuseLibrary: reuseLibrary,
      reuseSourceSnapshots: reuseSourceSnapshots,
      reuseCaptureService: reuseCaptureService,
      reuseSourceSnapshotService: reuseSourceSnapshotService,
      libraryReuseService: libraryReuseService,
      onReuseLibraryChanged: onReuseLibraryChanged,
      onReuseSourceSnapshotsChanged: onReuseSourceSnapshotsChanged,
      reuseSnapshotsRootPath: reuseSnapshotsRootPath,
      workspaceRootPath: workspaceRootPath,
    );
  }

  static WorkshopProductionLifecycleBundle createForWorkspace({
    required String workspaceRootPath,
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    WorkshopBuildLab? buildLab,
    Iterable<WorkshopBuildProvider> buildProviders =
        const <WorkshopBuildProvider>[],
    WorkshopReuseLibrary? reuseLibrary,
    Future<void> Function(WorkshopReuseLibrary)? onReuseLibraryChanged,
    WorkshopReuseSourceSnapshotIndex? reuseSourceSnapshots,
    WorkshopReuseCaptureService reuseCaptureService =
        const WorkshopReuseCaptureService(),
    WorkshopReuseSourceSnapshotService reuseSourceSnapshotService =
        const WorkshopReuseSourceSnapshotService(),
    WorkshopLibraryReuseService? libraryReuseService,
    WorkshopWebResearchService? webResearchService,
    Future<void> Function(WorkshopReuseSourceSnapshotIndex)?
        onReuseSourceSnapshotsChanged,
    String? reuseSnapshotsRootPath,
    String? workspaceRootPath,
    bool includeHiddenFiles = false,
    int maxFileSizeBytes = 10 * 1024 * 1024,
  }) {
    final normalizedWorkspaceRootPath = workspaceRootPath.trim();
    final executor = WorkshopFactory.createProjectExecutor(
      workspaceRootPath: normalizedWorkspaceRootPath,
      includeHiddenFiles: includeHiddenFiles,
      maxFileSizeBytes: maxFileSizeBytes,
    );
    final resolvedBuildLab = buildLab ??
        (buildProviders.isEmpty
            ? null
            : WorkshopBuildLab(
                providers: WorkshopBuildProviderPolicy.remotePreferred(
                  buildProviders,
                ),
              ));

    return create(
      projectExecutor: executor,
      inferenceService: inferenceService,
      assignments: assignments,
      buildLab: resolvedBuildLab,
      reuseLibrary: reuseLibrary,
      onReuseLibraryChanged: onReuseLibraryChanged,
      reuseSourceSnapshots: reuseSourceSnapshots,
      reuseCaptureService: reuseCaptureService,
      reuseSourceSnapshotService: reuseSourceSnapshotService,
      libraryReuseService: libraryReuseService,
      webResearchService: webResearchService,
      onReuseSourceSnapshotsChanged: onReuseSourceSnapshotsChanged,
      reuseSnapshotsRootPath: reuseSnapshotsRootPath,
      workspaceRootPath: normalizedWorkspaceRootPath,
    );
  }

  static Future<WorkshopProductionLifecycleBundle>
      createForWorkspaceWithPersistedReuse({
    required String workspaceRootPath,
    required PreferencesService preferences,
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    WorkshopBuildLab? buildLab,
    Iterable<WorkshopBuildProvider> buildProviders =
        const <WorkshopBuildProvider>[],
    WorkshopReuseCaptureService reuseCaptureService =
        const WorkshopReuseCaptureService(),
    WorkshopReuseSourceSnapshotService reuseSourceSnapshotService =
        const WorkshopReuseSourceSnapshotService(),
    WorkshopLibraryReadClient? libraryReadClient,
    WorkshopWebResearchService? webResearchService,
    bool includeHiddenFiles = false,
    int maxFileSizeBytes = 10 * 1024 * 1024,
  }) async {
    final normalizedWorkspaceRootPath = workspaceRootPath.trim();
    final reuseStore = WorkshopReuseLibraryStore(preferences: preferences);
    final snapshotStore =
        WorkshopReuseSourceSnapshotStore(preferences: preferences);
    final reuseLibrary = await reuseStore.load();
    final reuseSourceSnapshots = await snapshotStore.load();
    final reuseSnapshotsRootPath =
        '$normalizedWorkspaceRootPath-reuse-snapshots';
    final resolvedLibraryClient =
        libraryReadClient ?? WorkshopLibraryReadAdapter();

    return createForWorkspace(
      workspaceRootPath: normalizedWorkspaceRootPath,
      inferenceService: inferenceService,
      assignments: assignments,
      buildLab: buildLab,
      buildProviders: buildProviders,
      reuseLibrary: reuseLibrary,
      onReuseLibraryChanged: reuseStore.save,
      reuseSourceSnapshots: reuseSourceSnapshots,
      reuseCaptureService: reuseCaptureService,
      reuseSourceSnapshotService: reuseSourceSnapshotService,
      libraryReuseService: WorkshopLibraryReuseService(
        client: resolvedLibraryClient,
      ),
      webResearchService: webResearchService,
      onReuseSourceSnapshotsChanged: snapshotStore.save,
      reuseSnapshotsRootPath: reuseSnapshotsRootPath,
      includeHiddenFiles: includeHiddenFiles,
      maxFileSizeBytes: maxFileSizeBytes,
    );
  }
}
