import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_composer.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';

/// Composition boundary that exposes the four Workshop brains as one
/// role-aware executor.
///
/// The executor reuses the existing shared [InferenceService] and the
/// role-specific Workshop assignments. It does not create any Assistant
/// dependency, runtime, storage, downloader or memory subsystem.
final class WorkshopRoleInferenceExecutorComposer {
  const WorkshopRoleInferenceExecutorComposer._();

  static WorkshopRoleInferenceExecutor compose({
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    WorkshopRoleGatewayFactory? gatewayFactory,
  }) {
    final router = WorkshopRoleInferenceComposer.compose(
      inferenceService: inferenceService,
      assignments: assignments,
      gatewayFactory: gatewayFactory,
    );

    return WorkshopRoleInferenceExecutor(
      router: router,
    );
  }
}
