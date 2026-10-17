import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_implementation_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_handoff_policy.dart';
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
    this.gateEvidenceBaseline,
    this.gateEvidenceStaged,
  });

  final WorkshopChangeProposal proposal;
  final WorkshopReviewVerdict review;
  final WorkshopValidationVerdict? validation;

  /// Captured at the rejected gate, scoped only to affected Engineer paths.
  /// The baseline is after Library reuse but before the initial Engineer
  /// proposal; the staged snapshot is the exact source judged by the gate.
  final Map<String, String>? gateEvidenceBaseline;
  final Map<String, String>? gateEvidenceStaged;

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
  })  : _inference = inference,
        _implementationRunner = WorkshopProposalImplementationRunner(
          inference: inference,
        ),
        _reviewRunner = WorkshopProposalReviewRunner(
          inference: inference,
        ),
        _validationRunner = WorkshopProposalValidationRunner(
          inference: inference,
        );

  final WorkshopStageRoleInference _inference;
  final WorkshopProposalImplementationRunner _implementationRunner;
  final WorkshopProposalReviewRunner _reviewRunner;
  final WorkshopProposalValidationRunner _validationRunner;

  // A gate rejection is authoritative; bounded retries only give the Engineer
  // another chance to satisfy the same unchanged review/validation gates.
  // Physical Manga Kids evidence showed the first repair can make progress yet
  // still miss explicit task constraints, so permit one final corrective pass.
  static const int _maxGateRepairAttempts = 2;

  Future<WorkshopTaskInferenceResult> run({
    required WorkspaceSession session,
    WorkshopPreflightInferenceResult? preflight,
    bool isOffline = false,
    CancellationToken? cancellationToken,
    void Function(WorkshopStage stage)? onStage,
  }) async {
    final revisionBaseline =
        Map<String, String>.from(session.workspace.snapshot);
    onStage?.call(WorkshopStage.implementation);
    final proposal = await _runInitialImplementation(
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
      onStage: onStage,
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
    void Function(WorkshopStage stage)? onStage,
  }) async {
    final revisionBaseline =
        Map<String, String>.from(session.workspace.snapshot);
    onStage?.call(WorkshopStage.implementation);
    final proposal = await _runInitialImplementationWithResumeContext(
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
      onStage: onStage,
    );
  }

  Future<WorkshopChangeProposal> _runInitialImplementation({
    required WorkspaceSession session,
    required WorkshopPreflightInferenceResult? preflight,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) async {
    try {
      return await _implementationRunner.run(
        session: session,
        preflight: preflight,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
    } on FormatException catch (error) {
      if (!_shouldRetryRepeatedEmptyCreate(
        session: session,
        error: error,
        cancellationToken: cancellationToken,
      )) {
        rethrow;
      }

      _emitEmptyCreateRecovery(session.context.request);
      return _implementationRunner.run(
        session: session,
        preflight: preflight,
        revisionFeedback: _emptyCreateRecoveryFeedback(session.context.request),
        revisionAttempt: 1,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
    }
  }

  Future<WorkshopChangeProposal> _runInitialImplementationWithResumeContext({
    required WorkspaceSession session,
    required WorkshopResumeContext resumeContext,
    required WorkshopPreflightInferenceResult? preflight,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) async {
    try {
      return await _implementationRunner.runWithResumeContext(
        session: session,
        resumeContext: resumeContext,
        preflight: preflight,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
    } on FormatException catch (error) {
      if (!_shouldRetryRepeatedEmptyCreate(
        session: session,
        error: error,
        cancellationToken: cancellationToken,
      )) {
        rethrow;
      }

      _emitEmptyCreateRecovery(session.context.request);
      return _implementationRunner.runWithResumeContext(
        session: session,
        resumeContext: resumeContext,
        preflight: preflight,
        revisionFeedback: _emptyCreateRecoveryFeedback(session.context.request),
        revisionAttempt: 1,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
    }
  }

  Future<WorkshopTaskInferenceResult> _reviewAndValidate({
    required WorkspaceSession session,
    required WorkshopChangeProposal proposal,
    required Map<String, String> revisionBaseline,
    WorkshopPreflightInferenceResult? preflight,
    WorkshopResumeContext? resumeContext,
    required bool isOffline,
    CancellationToken? cancellationToken,
    void Function(WorkshopStage stage)? onStage,
  }) async {
    var implementationPlan = preflight?.architecture?.text;
    var currentProposal = proposal;
    var repairAttempts = 0;
    var specialistHandoffUsed = false;

    while (true) {
      onStage?.call(WorkshopStage.review);
      final review = await _reviewRunner.run(
        session: session,
        implementationPlan: implementationPlan,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );

      if (!review.approved) {
        if (repairAttempts >= _maxGateRepairAttempts ||
            cancellationToken?.isCancelled == true) {
          return _rejectedGateResult(
            session: session,
            proposal: currentProposal,
            review: review,
            baseline: revisionBaseline,
          );
        }

        final target = WorkshopRoleHandoffPolicy.forRejectedReview(review);
        var specialistFeedback = '';
        if (target != WorkshopRoleHandoffTarget.engineer) {
          // Only one specialist round-trip per task. Repeated requests for a
          // different owner remain blocked instead of looping or widening scope.
          if (specialistHandoffUsed) {
            return _rejectedGateResult(
              session: session,
              proposal: currentProposal,
              review: review,
              baseline: revisionBaseline,
            );
          }
          specialistHandoffUsed = true;
          final advice = await _requestSpecialistAdvice(
            session: session,
            review: review,
            target: target,
            attempt: repairAttempts + 1,
            isOffline: isOffline,
            cancellationToken: cancellationToken,
            onStage: onStage,
          );
          if (advice == null) {
            return _rejectedGateResult(
              session: session,
              proposal: currentProposal,
              review: review,
              baseline: revisionBaseline,
            );
          }
          specialistFeedback = advice;
          implementationPlan = <String>[
            if (implementationPlan != null) implementationPlan,
            'Specialist advisory within owner-authorized scope: $advice',
          ].join('\n');
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
        onStage?.call(WorkshopStage.implementation);
        currentProposal = await _runRevision(
          session: session,
          preflight: preflight,
          resumeContext: resumeContext,
          feedback: specialistFeedback.isEmpty
              ? _reviewFeedback(review)
              : '$specialistFeedback ${_reviewFeedback(review)}',
          attempt: repairAttempts,
          isOffline: isOffline,
          cancellationToken: cancellationToken,
        );
        continue;
      }

      onStage?.call(WorkshopStage.validation);
      final validation = await _validationRunner.run(
        session: session,
        implementationPlan: implementationPlan,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );

      if (validation.valid) {
        return WorkshopTaskInferenceResult(
          proposal: currentProposal,
          review: review,
          validation: validation,
        );
      }
      if (repairAttempts >= _maxGateRepairAttempts ||
          cancellationToken?.isCancelled == true) {
        return _rejectedGateResult(
          session: session,
          proposal: currentProposal,
          review: review,
          validation: validation,
          baseline: revisionBaseline,
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
      onStage?.call(WorkshopStage.implementation);
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

  /// Read-only specialist handoff requested by an explicit Reviewer marker.
  ///
  /// Advisory inference never edits the task graph, owner requirements,
  /// authorized paths, approval status or physical workspace.
  Future<String?> _requestSpecialistAdvice({
    required WorkspaceSession session,
    required WorkshopReviewVerdict review,
    required WorkshopRoleHandoffTarget target,
    required int attempt,
    required bool isOffline,
    CancellationToken? cancellationToken,
    void Function(WorkshopStage stage)? onStage,
  }) async {
    final request = session.context.request;
    if (cancellationToken?.isCancelled == true) return null;

    final stages = target == WorkshopRoleHandoffTarget.orchestrator
        ? <WorkshopStage>[WorkshopStage.analysis, WorkshopStage.planning]
        : <WorkshopStage>[WorkshopStage.planning];
    var earlierAdvice = '';
    final scope = request.targetFiles.isEmpty
        ? 'No path preselected by current CREATE task; do not invent paths.'
        : request.targetFiles.join(' | ');
    try {
      for (final stage in stages) {
        if (cancellationToken?.isCancelled == true) return null;
        onStage?.call(stage);
        final reviewSummary = <String>[
          review.summary,
          ...review.findings.where((f) => !f.startsWith('HANDOFF:')),
        ].join(' | ');
        final prompt = <String>[
          'CANTIERE SPECIALIST HANDOFF — READ ONLY',
          'Current owner task: ${request.title}',
          'Exact owner instruction: ${request.instruction}',
          'Owner constraints: ${request.constraints.join(' | ')}',
          'Authorized file scope: $scope',
          'Reviewer rejection: ${_shortHandoffText(reviewSummary, 600)}',
          if (earlierAdvice.isNotEmpty)
            'Orchestrator analysis: $earlierAdvice',
          'Give brief technical guidance for the CURRENT task only.',
          'Do not add user requirements, expand file access, write files, '
              'approve a gate or change project identity.',
        ].join('\n');
        final response = await _inference.complete(
          stage: stage,
          prompt: prompt,
          systemPrompt:
              'You are the Cantiere specialist called back to fix a rejected '
              'bounded task. Provide read-only advisory reasoning, not new '
              'owner requirements, new permissions or approval.',
          sessionId: 'workshop:${request.id}:specialist-handoff:'
              '${stage.name}:$attempt',
          isOffline: isOffline,
          maxTokens: 256,
          temperature: 0.1,
          cancellationToken: cancellationToken,
        );
        if (!response.isSuccessful || !response.hasText) {
          RuntimeEventLog.instance.emit(
            '[WORKSHOP_ROLE_HANDOFF] target=${target.name} '
            'stage=${stage.name} status=failed',
          );
          return null;
        }
        earlierAdvice = _shortHandoffText(response.text, 420);
      }
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_ROLE_HANDOFF] target=${target.name} status=advice_ready '
        'stages=${stages.length}',
      );
      return 'Specialist ${target.name} guidance: $earlierAdvice. '
          'Preserve exact owner instruction, constraints and permitted files.';
    } catch (error) {
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_ROLE_HANDOFF] target=${target.name} '
        'status=failed error_type=${error.runtimeType}',
      );
      return null;
    }
  }

  static String _shortHandoffText(String raw, int chars) {
    final text = raw.trim();
    return text.length <= chars ? text : text.substring(0, chars);
  }

  static WorkshopTaskInferenceResult _rejectedGateResult({
    required WorkspaceSession session,
    required WorkshopChangeProposal proposal,
    required WorkshopReviewVerdict review,
    WorkshopValidationVerdict? validation,
    required Map<String, String> baseline,
  }) {
    final current = session.workspace.snapshot;
    final before = <String, String>{};
    final after = <String, String>{};
    for (final path in proposal.affectedPaths) {
      if (baseline.containsKey(path)) before[path] = baseline[path]!;
      if (current.containsKey(path)) after[path] = current[path]!;
    }
    return WorkshopTaskInferenceResult(
      proposal: proposal,
      review: review,
      validation: validation,
      gateEvidenceBaseline: Map<String, String>.unmodifiable(before),
      gateEvidenceStaged: Map<String, String>.unmodifiable(after),
    );
  }

  Future<WorkshopChangeProposal> _runRevision({
    required WorkspaceSession session,
    required WorkshopPreflightInferenceResult? preflight,
    required WorkshopResumeContext? resumeContext,
    required String feedback,
    required int attempt,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) async {
    Future<WorkshopChangeProposal> runOnce(String revisionFeedback) {
      if (resumeContext != null) {
        return _implementationRunner.runWithResumeContext(
          session: session,
          resumeContext: resumeContext,
          preflight: preflight,
          revisionFeedback: revisionFeedback,
          revisionAttempt: attempt,
          isOffline: isOffline,
          cancellationToken: cancellationToken,
        );
      }

      return _implementationRunner.run(
        session: session,
        preflight: preflight,
        revisionFeedback: revisionFeedback,
        revisionAttempt: attempt,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
    }

    try {
      return await runOnce(feedback);
    } on FormatException catch (error) {
      if (!_shouldRetryRepeatedEmptyCreate(
        session: session,
        error: error,
        cancellationToken: cancellationToken,
      )) {
        rethrow;
      }

      _emitEmptyCreateRecovery(
        session.context.request,
        phase: 'revision',
        attempt: attempt,
      );
      return runOnce(
        <String>[
          _emptyCreateRecoveryFeedback(session.context.request),
          feedback,
        ].join(' '),
      );
    }
  }

  static bool _shouldRetryRepeatedEmptyCreate({
    required WorkspaceSession session,
    required FormatException error,
    CancellationToken? cancellationToken,
  }) {
    final message = error.message.toString();
    return cancellationToken?.isCancelled != true &&
        session.context.request.operation == WorkshopOperation.create &&
        (message == 'Workshop proposal must contain at least one file change.' ||
            message ==
                'Workshop create proposal must materialize required target '
                    '"lib/main.dart".');
  }

  static String _emptyCreateRecoveryFeedback(WorkshopRequest request) {
    final targets = request.targetFiles;
    final preferredTarget = targets.contains('lib/main.dart')
        ? 'lib/main.dart'
        : targets.isNotEmpty
            ? targets.first
            : 'lib/main.dart';
    return 'The Engineer already failed CREATE materialization after its '
        'structured-output repair. This final recovery must produce at least '
        'one real file change. If "lib/main.dart" is in targetFiles and does '
        'not yet exist, changes MUST include one complete non-deletion change '
        'to "lib/main.dart". Prefer one complete compilable change to '
        '"$preferredTarget". When targetFiles is non-empty, use only an allowed '
        'target. Do not answer with explanation-only text, planning, an empty '
        'changes array, or a proposal that omits the required entry point.';
  }

  static void _emitEmptyCreateRecovery(
    WorkshopRequest request, {
    String phase = 'initial',
    int? attempt,
  }) {
    RuntimeEventLog.instance.emit(
      '[WORKSHOP_EMPTY_CREATE_RECOVERY] request=${request.id} '
      'phase=$phase '
      'attempt=${attempt ?? 0} '
      'targets=${request.targetFiles.length}',
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
