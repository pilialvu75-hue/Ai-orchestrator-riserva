import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_implementation_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

/// Result of one Cantiere task inference cycle up to the explicit apply gate.
///
/// Approval and real workspace mutation are intentionally not part of this
/// result. A successful cycle ends with the session still in validation and
/// therefore still requires the existing explicit owner approval/apply path.
final class WorkshopTaskInferenceResult {
  const WorkshopTaskInferenceResult({
    required this.proposal,
    required this.review,
    this.validation,
  });

  final WorkshopChangeProposal proposal;
  final WorkshopReviewVerdict review;
  final WorkshopValidationVerdict? validation;

  bool get readyForApproval =>
      review.approved && validation?.valid == true;
}

/// Runs an already prepared Workshop task through the existing role-aware
/// Cantiere stages:
///
/// Engineer -> VirtualWorkspace -> Reviewer review -> Reviewer validation.
///
/// A completed Orchestrator/Architect preflight can be supplied to the
/// Engineer as bounded Workshop-only implementation guidance. The same
/// [WorkshopStageRoleInference] boundary is reused for every stage, preserving
/// the current role/model assignments and shared runtime. No Assistant
/// configuration, model selection, memory or conversation state is read or
/// used as fallback.
///
/// This pipeline deliberately stops before owner approval and apply. It never
/// writes to the real workspace, commits, pushes or creates a Pull Request.
final class WorkshopTaskInferencePipeline {
  WorkshopTaskInferencePipeline({
    required WorkshopStageRoleInference inference,
  })  : _implementationRunner = WorkshopProposalImplementationRunner(
          inference: inference,
        ),
        _reviewRunner = WorkshopProposalReviewRunner(
          inference: inference,
        ),
        _validationRunner = WorkshopProposalValidationRunner(
          inference: inference,
        );

  final WorkshopProposalImplementationRunner _implementationRunner;
  final WorkshopProposalReviewRunner _reviewRunner;
  final WorkshopProposalValidationRunner _validationRunner;

  Future<WorkshopTaskInferenceResult> run({
    required WorkspaceSession session,
    WorkshopPreflightInferenceResult? preflight,
    bool isOffline = true,
    CancellationToken? cancellationToken,
  }) async {
    final proposal = await _implementationRunner.run(
      session: session,
      preflight: preflight,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    final review = await _reviewRunner.run(
      session: session,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    if (!review.approved) {
      return WorkshopTaskInferenceResult(
        proposal: proposal,
        review: review,
      );
    }

    final validation = await _validationRunner.run(
      session: session,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    return WorkshopTaskInferenceResult(
      proposal: proposal,
      review: review,
      validation: validation,
    );
  }
}
