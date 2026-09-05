import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';

typedef WorkshopRoleGatewayFactory = WorkshopInferenceGateway Function(
  AppAiRole role,
);

/// Composes the four logical Workshop brains on top of the existing shared
/// inference infrastructure.
///
/// This class deliberately creates no runtime, storage, downloader or memory
/// subsystem. Each gateway is produced through [WorkshopFactory], which keeps
/// the role-specific model assignment explicit while reusing the application's
/// existing [InferenceService].
final class WorkshopRoleInferenceComposer {
  const WorkshopRoleInferenceComposer._();

  static WorkshopRoleInferenceRouter compose({
    InferenceService? inferenceService,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    WorkshopRoleGatewayFactory? gatewayFactory,
  }) {
    final buildGateway = gatewayFactory ??
        (AppAiRole role) => WorkshopFactory.createInferenceGateway(
              inferenceService: inferenceService,
              role: role,
              assignments: assignments,
            );

    return WorkshopRoleInferenceRouter(
      gateways: <AppAiRole, WorkshopInferenceGateway>{
        for (final role in WorkshopRoleInferenceRouter.workshopRoles)
          role: buildGateway(role),
      },
    );
  }
}
