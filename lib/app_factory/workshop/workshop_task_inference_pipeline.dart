import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_implementation_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

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

  static const int _maxGateRepairAttempts = 1;

  Future<WorkshopTaskInferenceResult> run({
    required WorkspaceSession session,
    WorkshopPreflightInferenceResult? preflight,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    final revisionBaseline =
        Map<String, String>.from(session.workspace.snapshot);
    final proposal = await _implementationRunner.run(
      session: session,
      preflight: preflight,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    return _reviewAndValidate(
      session: session,
      proposal: proposal,
      revisionBaseline: revisionBaseline,
      preflight: preflight,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );
  }

  /// Continues an already prepared task from the authoritative semantic state
  /// supplied by the Cantiere.
  ///
  /// Only the Engineer stage consumes the resume context and execution
  /// identity. Review and validation keep their existing contracts and inspect
  /// the proposal staged into the same WorkspaceSession. No second workspace,
  /// task state or provider-owned conversation is created here.
  Future<WorkshopTaskInferenceResult> runWithResumeContext({
    required WorkspaceSession session,
    required WorkshopResumeContext resumeContext,
    WorkshopPreflightInferenceResult? preflight,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    final revisionBaseline =
        Map<String, String>.from(session.workspace.snapshot);
    final proposal = await _implementationRunner.runWithResumeContext(
      session: session,
      resumeContext: resumeContext,
      preflight: preflight,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    return _reviewAndValidate(
      session: session,
      proposal: proposal,
      revisionBaseline: revisionBaseline,
      preflight: preflight,
      resumeContext: resumeContext,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );
  }

  Future<WorkshopTaskInferenceResult> _reviewAndValidate({
    required WorkspaceSession session,
    required WorkshopChangeProposal proposal,
    required Map<String, String> revisionBaseline,
    WorkshopPreflightInferenceResult? preflight,
    WorkshopResumeContext? resumeContext,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) async {
    final implementationPlan = preflight?.architecture?.text;
    var currentProposal = proposal;
    var repairAttempts = 0;

    while (true) {
      final review = await _reviewRunner.run(
        session: session,
        implementationPlan: implementationPlan,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );

      if (!review.approved) {
        if (repairAttempts >= _maxGateRepairAttempts ||
            cancellationToken?.isCancelled == true) {
          return WorkshopTaskInferenceResult(
            proposal: currentProposal,
            review: review,
          );
        }

        repairAttempts += 1;
        _emitGateRepair(
          source: 'review',
          attempt: repairAttempts,
          summaryChars: review.summary.length,
          issues: review.findings.length,
          warnings: review.warnings.length,
        );
        session.prepareRevisionAfterRejectedProposal(
          baselineSnapshot: revisionBaseline,
          proposalPaths: currentProposal.affectedPaths,
        );
        currentProposal = await _runRevision(
          session: session,
          preflight: preflight,
          resumeContext: resumeContext,
          feedback: _reviewFeedback(review),
          attempt: repairAttempts,
          isOffline: isOffline,
          cancellationToken: cancellationToken,
        );
        continue;
      }

      final validation = await _validationRunner.run(
        session: session,
        implementationPlan: implementationPlan,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );

      if (validation.valid ||
          repairAttempts >= _maxGateRepairAttempts ||
          cancellationToken?.isCancelled == true) {
        return WorkshopTaskInferenceResult(
          proposal: currentProposal,
          review: review,
          validation: validation,
        );
      }

      repairAttempts += 1;
      _emitGateRepair(
        source: 'validation',
        attempt: repairAttempts,
        summaryChars: validation.summary.length,
        issues: validation.checks.length,
        warnings: validation.warnings.length,
      );
      session.prepareRevisionAfterRejectedProposal(
        baselineSnapshot: revisionBaseline,
        proposalPaths: currentProposal.affectedPaths,
      );
      currentProposal = await _runRevision(
        session: session,
        preflight: preflight,
        resumeContext: resumeContext,
        feedback: _validationFeedback(validation),
        attempt: repairAttempts,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
    }
  }

  Future<WorkshopChangeProposal> _runRevision({
    required WorkspaceSession session,
    required WorkshopPreflightInferenceResult? preflight,
    required WorkshopResumeContext? resumeContext,
    required String feedback,
    required int attempt,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) {
    if (resumeContext != null) {
      return _implementationRunner.runWithResumeContext(
        session: session,
        resumeContext: resumeContext,
        preflight: preflight,
        revisionFeedback: feedback,
        revisionAttempt: attempt,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
    }

    return _implementationRunner.run(
      session: session,
      preflight: preflight,
      revisionFeedback: feedback,
      revisionAttempt: attempt,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );
  }

  static String _reviewFeedback(WorkshopReviewVerdict verdict) {
    return <String>[
      'Reviewer rejected the previous staged proposal.',
      verdict.summary,
      ...verdict.findings.map((finding) => 'Finding: $finding'),
      ...verdict.warnings.map((warning) => 'Warning: $warning'),
    ].join(' ');
  }

  static String _validationFeedback(WorkshopValidationVerdict verdict) {
    return <String>[
      'Validation rejected the previous staged proposal.',
      verdict.summary,
      ...verdict.checks.map((check) => 'Check: $check'),
      ...verdict.warnings.map((warning) => 'Warning: $warning'),
    ].join(' ');
  }

  static void _emitGateRepair({
    required String source,
    required int attempt,
    required int summaryChars,
    required int issues,
    required int warnings,
  }) {
    RuntimeEventLog.instance.emit(
      '[WORKSHOP_GATE_REPAIR] source=$source attempt=$attempt '
      'summary_chars=$summaryChars issues=$issues warnings=$warnings',
    );
  }
}
