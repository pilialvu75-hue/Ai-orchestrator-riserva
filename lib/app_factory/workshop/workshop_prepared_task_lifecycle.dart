import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_inference_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_approval_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

/// User-safe failure raised when a supplied Orchestrator/Architect preflight
/// did not complete and therefore must not be forwarded to the Engineer.
///
/// The technical runtime notice remains available for diagnostics, while
/// [toString] deliberately exposes only a bounded Cantiere message so the UI
/// does not surface internal `Bad state` implementation details.
final class WorkshopPreflightIncompleteException implements Exception {
  const WorkshopPreflightIncompleteException({
    required this.failedStage,
    this.runtimeNotice,
  });

  final String failedStage;
  final String? runtimeNotice;

  @override
  String toString() =>
      'Preflight del Cantiere incompleto: fase $failedStage non terminata. '
      'Riprova.';
}

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
  /// Reviewer validation, optionally handing a completed Cantiere preflight to
  /// the Engineer.
  ///
  /// A successful result is ready for an explicit owner decision but performs
  /// no real workspace mutation.
  Future<WorkshopTaskInferenceResult> runPrepared({
    required String taskId,
    WorkshopPreflightInferenceResult? preflight,
    bool isOffline = false,
    CancellationToken? cancellationToken,
    void Function(WorkshopStage stage)? onStage,
  }) {
    _requireCompletePreflight(preflight);
    return _inferenceRunner.run(
      taskId: taskId,
      preflight: preflight,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
      onStage: onStage,
    );
  }

  /// Resumes the same prepared task from Cantiere-owned semantic state.
  ///
  /// This is additive to [runPrepared] so existing callers keep their stable
  /// lifecycle contract. The resume context is only forwarded to the existing
  /// prepared-task runner; this lifecycle does not create or own checkpoint,
  /// execution, attempt, workspace or provider state.
  Future<WorkshopTaskInferenceResult> runPreparedWithResumeContext({
    required String taskId,
    required WorkshopResumeContext resumeContext,
    WorkshopPreflightInferenceResult? preflight,
    bool isOffline = false,
    CancellationToken? cancellationToken,
    void Function(WorkshopStage stage)? onStage,
  }) {
    _requireCompletePreflight(preflight);
    return _inferenceRunner.runWithResumeContext(
      taskId: taskId,
      resumeContext: resumeContext,
      preflight: preflight,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
      onStage: onStage,
    );
  }

  void _requireCompletePreflight(WorkshopPreflightInferenceResult? preflight) {
    if (preflight == null || preflight.readyForImplementation) {
      return;
    }

    final analysisReady = preflight.analysisReady;
    final failedResult =
        analysisReady ? preflight.architecture : preflight.analysis;

    throw WorkshopPreflightIncompleteException(
      failedStage: analysisReady ? 'Architetto' : 'Orchestratore',
      runtimeNotice: failedResult?.runtimeNotice,
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
