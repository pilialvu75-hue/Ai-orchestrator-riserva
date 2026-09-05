import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';

/// Logical inference phases owned by the Workshop.
///
/// These phases describe which specialist brain is responsible for a piece of
/// Workshop reasoning without coupling the Engine to a concrete runtime or
/// model implementation.
enum WorkshopInferencePhase {
  orchestration,
  architecture,
  implementation,
  review,
}

/// Stable mapping between Workshop reasoning phases and Workshop AI roles.
///
/// The Assistant is deliberately absent. This policy exists so the Engine can
/// adopt role-aware inference incrementally without duplicating runtimes,
/// storage, downloaders or memory.
abstract final class WorkshopRolePhasePolicy {
  static AppAiRole roleFor(WorkshopInferencePhase phase) {
    switch (phase) {
      case WorkshopInferencePhase.orchestration:
        return AppAiRole.workshopOrchestrator;
      case WorkshopInferencePhase.architecture:
        return AppAiRole.architect;
      case WorkshopInferencePhase.implementation:
        return AppAiRole.engineer;
      case WorkshopInferencePhase.review:
        return AppAiRole.reviewer;
    }
  }

  static const Set<AppAiRole> workshopRoles = <AppAiRole>{
    AppAiRole.workshopOrchestrator,
    AppAiRole.architect,
    AppAiRole.engineer,
    AppAiRole.reviewer,
  };
}
