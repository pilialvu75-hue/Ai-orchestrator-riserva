import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

/// Executes the final real-workspace apply step after explicit owner approval.
///
/// This runner deliberately delegates to [WorkspaceSession.apply], which
/// remains the single authoritative approval/validation guardrail and the
/// shared [VirtualWorkspace] mutation path. It does not duplicate those
/// invariants, commit, push or create a Pull Request, and it does not read
/// Assistant configuration, models, memory or conversation state.
final class WorkshopApprovedApplyRunner {
  const WorkshopApprovedApplyRunner();

  Future<void> run({required WorkspaceSession session}) async {
    await session.apply();
  }
}
