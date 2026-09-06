import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_multi_role_pipeline_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_lifecycle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_approval_controller.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';

/// Production-facing Cantiere composition returned to the UI layer.
///
/// The dashboard and the prepared-task lifecycle share the same authoritative
/// [WorkshopProjectExecutor]. This is important: a task prepared by the
/// dashboard is therefore the exact same WorkspaceSession consumed by the
/// Engineer -> Reviewer -> Reviewer pipeline and by the explicit approval/apply
/// boundary.
///
/// The bundle owns no second runtime, downloader, model store, workspace or
/// memory subsystem. The Assistant role is never accepted by the multi-role
/// router.
final class WorkshopProductionLifecycleBundle {
  const WorkshopProductionLifecycleBundle({
    required this.dashboardController,
    required this.taskLifecycle,
    required this.projectExecutor,
  });

  final WorkshopDashboardController dashboardController;
  final WorkshopPreparedTaskLifecycle taskLifecycle;

  /// Authoritative executor shared by dashboard preparation, inference and
  /// explicit approval/apply. Exposed only so a UI boundary can recover the
  /// exact prepared WorkspaceSession instead of constructing a second one.
  final WorkshopProjectExecutor projectExecutor;
}

/// Composes the existing Workshop production pieces around one shared project
/// executor.
///
/// This class deliberately delegates all lower-level construction to the
/// existing Workshop factories. It exists only to keep the UI from creating a
/// second ProjectExecutor or accidentally running inference against a different
/// WorkspaceSession from the one prepared by the dashboard.
abstract final class WorkshopProductionLifecycleBundleFactory {
  static WorkshopProductionLifecycleBundle create({
    required WorkshopProjectExecutor projectExecutor,
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    Map<AppAiRole, WorkshopInferenceGateway>? roleGateways,
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

    final inferenceRunner =
        WorkshopMultiRolePipelineFactory.createPreparedTaskRunner(
      executor: projectExecutor,
      inferenceService: inferenceService,
      assignments: assignments,
      gateways: roleGateways,
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
      taskLifecycle: lifecycle,
      projectExecutor: projectExecutor,
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
    final executor = WorkshopFactory.createProjectExecutor(
      workspaceRootPath: workspaceRootPath,
      includeHiddenFiles: includeHiddenFiles,
      maxFileSizeBytes: maxFileSizeBytes,
    );

    return create(
      projectExecutor: executor,
      inferenceService: inferenceService,
      assignments: assignments,
    );
  }
}
