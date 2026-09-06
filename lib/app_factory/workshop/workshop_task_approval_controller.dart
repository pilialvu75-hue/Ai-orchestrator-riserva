import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';

/// Bridges the explicit owner approval decision to the existing project
/// executor without collapsing approval and apply into one operation.
///
/// The controller deliberately keeps two distinct calls:
/// 1. [decide] records the explicit owner decision through the existing
///    [WorkshopApplyApprovalGate];
/// 2. [applyApproved] delegates the real workspace mutation to the existing
///    [WorkshopProjectExecutor].
///
/// It does not call an LLM, does not read Assistant configuration or memory,
/// and does not commit, push or create pull requests.
final class WorkshopTaskApprovalController {
  const WorkshopTaskApprovalController({
    required WorkshopProjectExecutor executor,
    WorkshopApplyApprovalGate gate = const WorkshopApplyApprovalGate(),
  })  : _executor = executor,
        _gate = gate;

  final WorkshopProjectExecutor _executor;
  final WorkshopApplyApprovalGate _gate;

  WorkspaceSession decide({
    required String taskId,
    required WorkshopApplyDecision decision,
    String rejectionReason = 'Workshop changes rejected by owner.',
  }) {
    final session = _requireSession(taskId);

    _gate.decide(
      session: session,
      decision: decision,
      rejectionReason: rejectionReason,
    );

    return session;
  }

  Future<WorkspaceSession> applyApproved(String taskId) {
    final normalizedTaskId = _normalizeTaskId(taskId);
    return _executor.applyApprovedTask(normalizedTaskId);
  }

  WorkspaceSession _requireSession(String taskId) {
    final normalizedTaskId = _normalizeTaskId(taskId);
    final session = _executor.sessionForTask(normalizedTaskId);

    if (session == null) {
      throw StateError(
        'No WorkspaceSession exists for task "$normalizedTaskId".',
      );
    }

    return session;
  }

  String _normalizeTaskId(String taskId) {
    final normalizedTaskId = taskId.trim();

    if (normalizedTaskId.isEmpty) {
      throw ArgumentError.value(
        taskId,
        'taskId',
        'Task id cannot be empty.',
      );
    }

    return normalizedTaskId;
  }
}
