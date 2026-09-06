import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_composer.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor_composer.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';

/// Production composition boundary for stage-aware Workshop inference.
///
/// The four Workshop roles are composed over the existing shared
/// [InferenceService]. No Assistant model selection, memory, runtime,
/// downloader or storage fallback is introduced here.
final class WorkshopStageRoleInferenceComposer {
  const WorkshopStageRoleInferenceComposer._();

  static WorkshopStageRoleInference compose({
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    WorkshopRoleGatewayFactory? gatewayFactory,
  }) {
    final executor = WorkshopRoleInferenceExecutorComposer.compose(
      inferenceService: inferenceService,
      assignments: assignments,
      gatewayFactory: gatewayFactory,
    );

    return WorkshopStageRoleInference(
      executor: executor,
    );
  }
}
