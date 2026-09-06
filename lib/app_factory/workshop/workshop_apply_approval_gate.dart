import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

/// Explicit owner decision for the final Workshop apply gate.
enum WorkshopApplyDecision {
  approve,
  reject,
}

/// Keeps validation, owner approval, and real workspace mutation as three
/// separate steps.
///
/// This gate only records the explicit decision on the existing
/// [WorkspaceSession]. It never calls [WorkspaceSession.apply] and therefore
/// cannot write to the real repository by itself.
final class WorkshopApplyApprovalGate {
  const WorkshopApplyApprovalGate();

  void decide({
    required WorkspaceSession session,
    required WorkshopApplyDecision decision,
    String rejectionReason = 'Workshop changes rejected by owner.',
  }) {
    if (session.status != WorkspaceSessionStatus.validation) {
      throw StateError(
        'Workshop apply approval can only be decided after successful '
        'validation. Current status: ${session.status.name}.',
      );
    }

    if (!session.hasChanges) {
      throw StateError(
        'Workshop apply approval requires staged workspace changes.',
      );
    }

    switch (decision) {
      case WorkshopApplyDecision.approve:
        session.approveApply();
        return;
      case WorkshopApplyDecision.reject:
        session.block(rejectionReason);
        return;
    }
  }
}
