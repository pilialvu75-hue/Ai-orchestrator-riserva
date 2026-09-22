import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

import 'workshop_airlab_capability.dart';

/// Typed fail-closed error raised when an AIrLab capability run cannot enter
/// the ordinary Cantiere review/validation lifecycle.
final class WorkshopAirLabInferenceBridgeException implements Exception {
  const WorkshopAirLabInferenceBridgeException(
    this.message, {
    required this.code,
    this.execution,
  });

  final String message;
  final String code;
  final WorkshopTaskExecutionResult? execution;

  @override
  String toString() =>
      'WorkshopAirLabInferenceBridgeException($code): $message';
}

/// Bridges A4 AIrLab execution into the same Reviewer/validation contract used
/// by the normal production inference pipeline.
///
/// The Engineer stage is replaced only for this explicitly selected AIrLab run:
///
///   guarded AIrLab execution
///       -> controlled staging
///       -> VirtualWorkspace.review
///       -> existing Reviewer
///       -> existing validation
///       -> WorkshopTaskInferenceResult
///
/// The real repository remains untouched. A successful run ends in
/// [WorkspaceSessionStatus.validation] and still requires the existing owner
/// approval/apply boundary.
final class WorkshopAirLabInferenceBridge {
  WorkshopAirLabInferenceBridge({
    required WorkshopAirLabCapability capability,
    required WorkshopStageRoleInference inference,
  })  : _capability = capability,
        _reviewRunner = WorkshopProposalReviewRunner(inference: inference),
        _validationRunner =
            WorkshopProposalValidationRunner(inference: inference);

  final WorkshopAirLabCapability _capability;
  final WorkshopProposalReviewRunner _reviewRunner;
  final WorkshopProposalValidationRunner _validationRunner;

  Future<WorkshopTaskInferenceResult> run({
    required WorkshopTaskContract task,
    required WorkspaceSession session,
    required String stagingRoot,
    bool networkAvailable = true,
    bool executionApprovalGranted = false,
    bool isOffline = false,
    String? projectId,
    String? target,
    CancellationToken? cancellationToken,
    WorkshopTaskExecutionProgressCallback? onProgress,
  }) async {
    _throwIfCancelled(cancellationToken);

    final capabilityResult = await _capability.run(
      task: task,
      session: session,
      stagingRoot: stagingRoot,
      networkAvailable: networkAvailable,
      executionApprovalGranted: executionApprovalGranted,
      projectId: projectId,
      target: target,
      onProgress: onProgress,
    );

    final promotion = capabilityResult.promotion;
    if (promotion == null) {
      final execution = capabilityResult.execution;
      final code = execution.metadata['code']?.toString().trim();
      throw WorkshopAirLabInferenceBridgeException(
        execution.message?.trim().isNotEmpty == true
            ? execution.message!.trim()
            : 'AIrLab execution did not produce a reviewable staged proposal.',
        code: code == null || code.isEmpty
            ? 'airlab_not_promoted'
            : code,
        execution: execution,
      );
    }

    if (session.status != WorkspaceSessionStatus.review) {
      throw WorkshopAirLabInferenceBridgeException(
        'AIrLab promotion did not leave the authoritative workspace in review.',
        code: 'workspace_review_state_invalid',
        execution: capabilityResult.execution,
      );
    }

    _throwIfCancelled(cancellationToken);

    final review = await _reviewRunner.run(
      session: session,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    if (!review.approved) {
      return WorkshopTaskInferenceResult(
        proposal: promotion.proposal,
        review: review,
      );
    }

    _throwIfCancelled(cancellationToken);

    final validation = await _validationRunner.run(
      session: session,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    return WorkshopTaskInferenceResult(
      proposal: promotion.proposal,
      review: review,
      validation: validation,
    );
  }

  void _throwIfCancelled(CancellationToken? cancellationToken) {
    if (cancellationToken?.isCancelled == true) {
      throw const WorkshopAirLabInferenceBridgeException(
        'AIrLab Cantiere bridge was cancelled.',
        code: 'cancelled',
      );
    }
  }
}
