import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_multi_role_pipeline_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_lifecycle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_approval_controller.dart';
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
    this.workspaceRootPath,
  });

  final WorkshopDashboardController dashboardController;

  /// Read-only Orchestrator -> Architect reasoning boundary composed from the
  /// same role-aware inference stack used by the prepared task lifecycle.
  final WorkshopPreflightInferencePipeline preflight;

  final WorkshopPreparedTaskLifecycle taskLifecycle;

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
      ),
      preflight: preflight,
      taskLifecycle: lifecycle,
      projectExecutor: projectExecutor,
      workspaceRootPath: workspaceRootPath,
    );
  }

  /// Creates the production bundle for a real local workspace while reusing
  /// the existing LocalGitWorkspaceGateway and shared inference service.
  static WorkshopProductionLifecycleBundle createForWorkspace({
    required String workspaceRootPath,
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    bool includeHiddenFiles = false,
    int maxFileSizeBytes = 10 * 1024 * 1024,
  }) {
    final normalizedWorkspaceRootPath = workspaceRootPath.trim();

    final executor = WorkshopFactory.createProjectExecutor(
      workspaceRootPath: normalizedWorkspaceRootPath,
      includeHiddenFiles: includeHiddenFiles,
      maxFileSizeBytes: maxFileSizeBytes,
    );

    return create(
      projectExecutor: executor,
      inferenceService: inferenceService,
      assignments: assignments,
      workspaceRootPath: normalizedWorkspaceRootPath,
    );
  }
}
