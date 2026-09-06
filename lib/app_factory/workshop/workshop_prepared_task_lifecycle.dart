import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_inference_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_approval_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

/// Coordinates the existing prepared-task inference and explicit owner
/// approval/apply boundaries without collapsing them into one operation.
///
/// This class owns no runtime, workspace, downloader, storage or model state.
/// It never reads Assistant configuration, model selection, memory or
/// conversation state. Owner approval remains an explicit caller action.
final class WorkshopPreparedTaskLifecycle {
  const WorkshopPreparedTaskLifecycle({
    required WorkshopPreparedTaskInferenceRunner inferenceRunner,
    required WorkshopTaskApprovalController approvalController,
  })  : _inferenceRunner = inferenceRunner,
        _approvalController = approvalController;

  final WorkshopPreparedTaskInferenceRunner _inferenceRunner;
  final WorkshopTaskApprovalController _approvalController;

  /// Runs the already-prepared task through Engineer -> Reviewer review ->
  /// Reviewer validation.
  ///
  /// A successful result is ready for an explicit owner decision but performs
  /// no real workspace mutation.
  Future<WorkshopTaskInferenceResult> runPrepared({
    required String taskId,
    bool isOffline = true,
    CancellationToken? cancellationToken,
  }) {
    return _inferenceRunner.run(
      taskId: taskId,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );
  }

  /// Records the owner's explicit decision. Approval alone never applies.
  WorkspaceSession decide({
    required String taskId,
    required WorkshopApplyDecision decision,
    String rejectionReason = 'Workshop changes rejected by owner.',
  }) {
    return _approvalController.decide(
      taskId: taskId,
      decision: decision,
      rejectionReason: rejectionReason,
    );
  }

  /// Applies an explicitly approved task and advances the authoritative plan
  /// only after the real workspace mutation succeeds.
  Future<WorkspaceSession> applyApprovedAndComplete({
    required WorkshopProjectPlan plan,
    required String taskId,
  }) {
    return _approvalController.applyApprovedAndComplete(
      plan: plan,
      taskId: taskId,
    );
  }
}
