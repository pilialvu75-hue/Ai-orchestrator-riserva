import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_inference_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_composer.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference_composer.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';

/// Adds prepared-task composition on top of the existing role-aware Cantiere
/// inference composers.
///
/// The authoritative [WorkshopRoleInferenceComposer] and
/// [WorkshopStageRoleInferenceComposer] remain responsible for building the
/// four Workshop brains over the shared [InferenceService]. This helper only
/// joins that existing stack to the prepared-task pipeline; it does not create
/// a parallel runtime, downloader, storage or Assistant dependency.
final class WorkshopMultiRolePipelineFactory {
  const WorkshopMultiRolePipelineFactory._();

  /// Exposes the authoritative Workshop router while preserving an explicit
  /// gateway injection seam for focused tests.
  static WorkshopRoleInferenceRouter createRouter({
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    Map<AppAiRole, WorkshopInferenceGateway>? gateways,
  }) {
    return WorkshopRoleInferenceComposer.compose(
      inferenceService: inferenceService,
      assignments: assignments,
      gatewayFactory: _gatewayFactory(gateways),
    );
  }

  static WorkshopStageRoleInference createStageInference({
    WorkshopRoleInferenceRouter? router,
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    Map<AppAiRole, WorkshopInferenceGateway>? gateways,
  }) {
    if (router != null) {
      if (gateways != null) {
        throw ArgumentError(
          'Provide either an existing Workshop router or explicit gateways, '
          'not both.',
        );
      }

      return WorkshopStageRoleInference(
        executor: WorkshopRoleInferenceExecutor(
          router: router,
        ),
      );
    }

    return WorkshopStageRoleInferenceComposer.compose(
      inferenceService: inferenceService,
      assignments: assignments,
      gatewayFactory: _gatewayFactory(gateways),
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

  static WorkshopRoleGatewayFactory? _gatewayFactory(
    Map<AppAiRole, WorkshopInferenceGateway>? gateways,
  ) {
    if (gateways == null) {
      return null;
    }

    if (gateways.containsKey(AppAiRole.assistantOrchestrator)) {
      throw ArgumentError(
        'Workshop pipeline gateways must not contain the Assistant role.',
      );
    }

    return (AppAiRole role) {
      final gateway = gateways[role];
      if (gateway == null) {
        throw ArgumentError(
          'Missing Workshop inference gateway for role "${role.id}".',
        );
      }
      return gateway;
    };
  }
}
