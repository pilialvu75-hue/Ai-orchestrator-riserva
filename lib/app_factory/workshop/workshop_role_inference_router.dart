import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';

/// Role-aware inference boundary for the Workshop.
///
/// The Workshop has four independent logical AI roles while still sharing the
/// same low-level inference infrastructure. This router keeps that distinction
/// explicit without creating a second runtime, downloader, storage layer or
/// Assistant dependency.
///
/// The Assistant role is deliberately rejected at this boundary.
final class WorkshopRoleInferenceRouter {
  WorkshopRoleInferenceRouter({
    required Map<AppAiRole, WorkshopInferenceGateway> gateways,
  }) : _gateways = Map<AppAiRole, WorkshopInferenceGateway>.unmodifiable(
          _validateGateways(gateways),
        );

  static const Set<AppAiRole> workshopRoles = <AppAiRole>{
    AppAiRole.workshopOrchestrator,
    AppAiRole.architect,
    AppAiRole.engineer,
    AppAiRole.reviewer,
  };

  final Map<AppAiRole, WorkshopInferenceGateway> _gateways;

  Set<AppAiRole> get roles => Set<AppAiRole>.unmodifiable(_gateways.keys);

  bool hasRole(AppAiRole role) => _gateways.containsKey(role);

  WorkshopInferenceGateway gatewayFor(AppAiRole role) {
    if (role == AppAiRole.assistantOrchestrator) {
      throw StateError(
        'The Assistant role cannot be routed through the Workshop.',
      );
    }

    final gateway = _gateways[role];
    if (gateway == null) {
      throw StateError(
        'No Workshop inference gateway is configured for role "${role.id}".',
      );
    }

    return gateway;
  }

  static Map<AppAiRole, WorkshopInferenceGateway> _validateGateways(
    Map<AppAiRole, WorkshopInferenceGateway> gateways,
  ) {
    if (gateways.containsKey(AppAiRole.assistantOrchestrator)) {
      throw ArgumentError(
        'WorkshopRoleInferenceRouter must not contain the Assistant role.',
      );
    }

    final missingRoles = workshopRoles.difference(gateways.keys.toSet());
    if (missingRoles.isNotEmpty) {
      throw ArgumentError(
        'WorkshopRoleInferenceRouter requires all Workshop roles. Missing: '
        '${missingRoles.map((role) => role.id).join(', ')}.',
      );
    }

    final unsupportedRoles = gateways.keys.toSet().difference(workshopRoles);
    if (unsupportedRoles.isNotEmpty) {
      throw ArgumentError(
        'Unsupported roles in WorkshopRoleInferenceRouter: '
        '${unsupportedRoles.map((role) => role.id).join(', ')}.',
      );
    }

    return gateways;
  }
}
