import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';

typedef WorkshopGatewayBuilder = WorkshopInferenceGateway Function(
  AppAiRole role,
);

/// Composes the four independent Workshop role gateways over the existing
/// inference infrastructure.
///
/// This composition layer deliberately has no Assistant fallback: every
/// Workshop role is resolved through its own Workshop model assignment and the
/// router rejects the Assistant role entirely.
final class WorkshopRoleInferenceComposition {
  const WorkshopRoleInferenceComposition._();

  static WorkshopRoleInferenceExecutor create({
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    WorkshopGatewayBuilder? gatewayBuilder,
  }) {
    final gateways = <AppAiRole, WorkshopInferenceGateway>{};

    for (final role in WorkshopRoleInferenceRouter.workshopRoles) {
      gateways[role] = gatewayBuilder?.call(role) ??
          WorkshopFactory.createInferenceGateway(
            inferenceService: inferenceService,
            role: role,
            assignments: assignments,
          );
    }

    return WorkshopRoleInferenceExecutor(
      router: WorkshopRoleInferenceRouter(
        gateways: gateways,
      ),
    );
  }
}
