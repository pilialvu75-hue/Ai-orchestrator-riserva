import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_provider_policy.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_multi_role_pipeline_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_lifecycle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_approval_controller.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';

/// Production-facing Cantiere composition returned to the UI layer.
///
/// The dashboard, read-only Orchestrator/Architect preflight and prepared-task
/// lifecycle share the same authoritative project executor. The preflight and
/// prepared-task lifecycle additionally share one role-aware inference stack;
/// the dashboard engine keeps its existing Orchestrator gateway while reusing
/// the same underlying inference service/model assignments when supplied.
/// A task prepared by the dashboard is therefore the exact same
/// WorkspaceSession consumed by the Engineer -> Reviewer -> Reviewer pipeline
/// and by the explicit approval/apply boundary.
///
/// The bundle owns no second runtime, downloader, model store, workspace or
/// memory subsystem. The Assistant role is never accepted by the multi-role
/// router.
final class WorkshopProductionLifecycleBundle {
  const WorkshopProductionLifecycleBundle({
    required this.dashboardController,
    required this.preflight,
    required this.taskLifecycle,
    required this.projectExecutor,
    this.reuseLibrary,
    this.workspaceRootPath,
  });

  final WorkshopDashboardController dashboardController;

  /// Read-only Orchestrator -> Architect reasoning boundary composed from the
  /// same role-aware inference stack used by the prepared task lifecycle.
  ///
  /// When [reuseLibrary] is available, the preflight can replace a redundant
  /// Orchestrator inference with verified local production knowledge while
  /// preserving the Architect and all downstream validation gates.
  final WorkshopPreflightInferencePipeline preflight;

  final WorkshopPreparedTaskLifecycle taskLifecycle;

  /// Verified local production knowledge available to the reuse-aware
  /// preflight. Null preserves the historical production behaviour.
  final WorkshopReuseLibrary? reuseLibrary;

  /// Authoritative executor shared by dashboard preparation, inference and
  /// explicit approval/apply. Exposed only so a UI boundary can recover the
  /// exact prepared WorkspaceSession instead of constructing a second one.
  final WorkshopProjectExecutor projectExecutor;

  /// Real local Cantiere workspace used by this production bundle, when the
  /// bundle was composed through [WorkshopProductionLifecycleBundleFactory.createForWorkspace].
  ///
  /// Keeping this path on the existing production composition lets later
  /// verification/build steps target the exact workspace that was approved and
  /// applied, without creating a second workspace or consulting Assistant
  /// state. Generic/test compositions may leave it null.
  final String? workspaceRootPath;
}

/// Composes the existing Workshop production pieces around one shared project
/// executor and one shared role-aware inference stack for preflight/task work.
///
/// This class deliberately delegates all lower-level construction to the
/// existing Workshop factories. It exists only to keep the UI from creating a
/// second ProjectExecutor, a second inference router, or accidentally running
/// inference against a different WorkspaceSession from the one prepared by the
/// dashboard.
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
    String? workspaceRootPath,
  }) {
    final orchestratorGateway =
        roleGateways?[AppAiRole.workshopOrchestrator];

    final engine = WorkshopFactory.createEngine(
      projectExecutor: projectExecutor,
      inferenceService: inferenceService,
      inferenceGateway: orchestratorGateway,
      role: AppAiRole.workshopOrchestrator,
      assignments: assignments,
    );

    final stageInference =
        WorkshopMultiRolePipelineFactory.createStageInference(
      inferenceService: inferenceService,
      assignments: assignments,
      gateways: roleGateways,
    );

    final preflight = WorkshopPreflightInferencePipeline(
      inference: stageInference,
      reuseLibrary: reuseLibrary,
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
      workspaceRootPath: workspaceRootPath,
    );
  }

  /// Creates the production bundle for a real local workspace while reusing
  /// the existing LocalGitWorkspaceGateway and shared inference service.
  ///
  /// When concrete build providers are supplied, production composition applies
  /// the shared Remote Preferred / Local Fallback ordering before exposing the
  /// Build Lab to the dashboard. Supplying an explicit [buildLab] still wins so
  /// tests or specialized hosts can provide a fully composed lab directly.
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
      workspaceRootPath: normalizedWorkspaceRootPath,
    );
  }

  /// Async production composition that restores the verified local reuse
  /// catalog before creating the preflight pipeline.
  ///
  /// Existing synchronous callers remain unchanged. App/UI composition can opt
  /// into this path when it already owns [PreferencesService], avoiding any new
  /// global storage system or Assistant dependency. Reuse evidence is persisted
  /// after a successful reuse-aware preflight.
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
    bool includeHiddenFiles = false,
    int maxFileSizeBytes = 10 * 1024 * 1024,
  }) async {
    final store = WorkshopReuseLibraryStore(
      preferences: preferences,
    );
    final reuseLibrary = await store.load();

    return createForWorkspace(
      workspaceRootPath: workspaceRootPath,
      inferenceService: inferenceService,
      assignments: assignments,
      buildLab: buildLab,
      buildProviders: buildProviders,
      reuseLibrary: reuseLibrary,
      onReuseLibraryChanged: store.save,
      includeHiddenFiles: includeHiddenFiles,
      maxFileSizeBytes: maxFileSizeBytes,
    );
  }
}
