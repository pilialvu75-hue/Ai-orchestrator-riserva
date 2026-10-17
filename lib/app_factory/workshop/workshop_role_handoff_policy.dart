import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';

/// A specialist can advise on a task, but cannot grant new file/scope rights.
enum WorkshopRoleHandoffTarget { engineer, architect, orchestrator }

/// An explicit Reviewer finding requests a specialist handoff.
///
/// Model prose and untrusted Web/source content cannot alter role ownership.
/// The canonical owner request, scope and gates remain unchanged.
abstract final class WorkshopRoleHandoffPolicy {
  static const String architectMarker = 'HANDOFF:ARCHITECT';
  static const String orchestratorMarker = 'HANDOFF:ORCHESTRATOR';

  static WorkshopRoleHandoffTarget forRejectedReview(
    WorkshopReviewVerdict verdict,
  ) {
    if (verdict.approved) return WorkshopRoleHandoffTarget.engineer;
    final markers = verdict.findings
        .map((item) => item.trim().toUpperCase())
        .toSet();
    if (markers.contains(orchestratorMarker)) {
      return WorkshopRoleHandoffTarget.orchestrator;
    }
    if (markers.contains(architectMarker)) {
      return WorkshopRoleHandoffTarget.architect;
    }
    return WorkshopRoleHandoffTarget.engineer;
  }
}
