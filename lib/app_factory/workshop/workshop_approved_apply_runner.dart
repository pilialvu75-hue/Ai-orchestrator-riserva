import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

/// Executes the final real-workspace apply step after explicit owner approval.
///
/// This runner deliberately reuses [WorkspaceSession.apply] so all existing
/// validation/approval guardrails and the shared [VirtualWorkspace] mutation
/// path remain authoritative. It does not commit, push or create a Pull
/// Request, and it does not read Assistant configuration, models, memory or
/// conversation state.
final class WorkshopApprovedApplyRunner {
  const WorkshopApprovedApplyRunner();

  Future<void> run({required WorkspaceSession session}) async {
    if (session.status != WorkspaceSessionStatus.approved ||
        !session.isApplyApproved) {
      throw StateError(
        'Workshop apply requires explicit owner approval. '
        'Current status: ${session.status.name}.',
      );
    }

    await session.apply();
  }
}
