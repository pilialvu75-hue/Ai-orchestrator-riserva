import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_inference_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';

/// Composes the role-aware Cantiere inference path from the existing shared
/// runtime infrastructure.
///
/// The four Workshop roles receive independent gateways/model assignments but
/// reuse the same [InferenceService]. No Assistant role, model selection,
/// configuration or memory is read or used as fallback.
final class WorkshopMultiRolePipelineFactory {
  const WorkshopMultiRolePipelineFactory._();

  /// Builds the authoritative router for all four Workshop roles.
  ///
  /// Explicit [gateways] are accepted for tests/integration boundaries. When
  /// omitted, one shared [InferenceService] is resolved once and each role gets
  /// its own Workshop gateway using the Cantiere assignments.
  static WorkshopRoleInferenceRouter createRouter({
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    Map<AppAiRole, WorkshopInferenceGateway>? gateways,
  }) {
    if (gateways != null) {
      return WorkshopRoleInferenceRouter(gateways: gateways);
    }

    final sharedInferenceService = WorkshopFactory.resolveInferenceService(
      inferenceService: inferenceService,
    );

    return WorkshopRoleInferenceRouter(
      gateways: <AppAiRole, WorkshopInferenceGateway>{
        for (final role in WorkshopRoleInferenceRouter.workshopRoles)
          role: WorkshopFactory.createInferenceGateway(
            inferenceService: sharedInferenceService,
            role: role,
            assignments: assignments,
          ),
      },
    );
  }

  static WorkshopStageRoleInference createStageInference({
    WorkshopRoleInferenceRouter? router,
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    Map<AppAiRole, WorkshopInferenceGateway>? gateways,
  }) {
    final resolvedRouter = router ??
        createRouter(
          inferenceService: inferenceService,
          assignments: assignments,
          gateways: gateways,
        );

    return WorkshopStageRoleInference(
      executor: WorkshopRoleInferenceExecutor(
        router: resolvedRouter,
      ),
    );
  }

  static WorkshopTaskInferencePipeline createTaskPipeline({
    WorkshopStageRoleInference? stageInference,
    WorkshopRoleInferenceRouter? router,
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    Map<AppAiRole, WorkshopInferenceGateway>? gateways,
  }) {
    return WorkshopTaskInferencePipeline(
      inference: stageInference ??
          createStageInference(
            router: router,
            inferenceService: inferenceService,
            assignments: assignments,
            gateways: gateways,
          ),
    );
  }

  /// Creates the prepared-task runner used by the project lifecycle.
  ///
  /// The runner still stops at validation. Explicit owner approval and real
  /// apply remain separate existing operations.
  static WorkshopPreparedTaskInferenceRunner createPreparedTaskRunner({
    required WorkshopProjectExecutor executor,
    WorkshopTaskInferencePipeline? pipeline,
    WorkshopStageRoleInference? stageInference,
    WorkshopRoleInferenceRouter? router,
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    Map<AppAiRole, WorkshopInferenceGateway>? gateways,
  }) {
    final resolvedPipeline = pipeline ??
        createTaskPipeline(
          stageInference: stageInference,
          router: router,
          inferenceService: inferenceService,
          assignments: assignments,
          gateways: gateways,
        );

    return WorkshopPreparedTaskInferenceRunner(
      executor: executor,
      pipeline: resolvedPipeline,
    );
  }
}
