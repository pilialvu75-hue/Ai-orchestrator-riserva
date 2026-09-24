import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_plan_projection.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Runs the Cantiere Reviewer against the current staged VirtualWorkspace.
///
/// This bridge reuses [WorkshopStageRoleInference], so the review stage is
/// routed to the existing Reviewer model assignment and shared runtime.
/// It reads only the active Workshop request/workspace and never imports
/// Assistant configuration, model selection, memory or conversation state.
///
/// A successful inference is passed to [WorkshopProposalReviewGate]:
/// - explicit approval advances review -> validation;
/// - rejection blocks the session;
/// - inference/format failures leave the session in review.
///
/// No real workspace write, commit, push or Pull Request is performed here.
final class WorkshopProposalReviewRunner {
  const WorkshopProposalReviewRunner({
    required WorkshopStageRoleInference inference,
    WorkshopProposalReviewGate gate = const WorkshopProposalReviewGate(),
  })  : _inference = inference,
        _gate = gate;

  final WorkshopStageRoleInference _inference;
  final WorkshopProposalReviewGate _gate;

  static const int _primaryMaxTokens = 256;
  static const int _retryMaxTokens = 192;
  static const int _primaryFileChars = 2400;
  static const int _retryFileChars = 1200;
  static const int _primaryContextChars = 320;
  static const int _retryContextChars = 160;

  Future<WorkshopReviewVerdict> run({
    required WorkspaceSession session,
    String? implementationPlan,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    if (session.status != WorkspaceSessionStatus.review) {
      throw StateError(
        'Workshop Reviewer can only run while the workspace session is in '
        'review. Current status: ${session.status.name}.',
      );
    }

    if (!session.hasChanges) {
      throw StateError(
        'Workshop Reviewer requires staged workspace changes.',
      );
    }

    final sessionId = 'workshop:review:${session.context.request.id}';
    var result = await _inference.complete(
      stage: WorkshopStage.review,
      prompt: _buildPrompt(
        session,
        implementationPlan: implementationPlan,
      ),
      systemPrompt: _systemPrompt,
      sessionId: sessionId,
      isOffline: isOffline,
      maxTokens: _primaryMaxTokens,
      cancellationToken: cancellationToken,
    );

    if (_shouldRetryReviewer(
      result,
      cancellationToken: cancellationToken,
    )) {
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_REVIEW_RETRY] '
        'attempt=2 terminal=${result.terminalState?.name ?? 'none'} '
        'chars=${result.text.length}',
      );

      result = await _inference.complete(
        stage: WorkshopStage.review,
        prompt: _buildPrompt(
          session,
          implementationPlan: implementationPlan,
          compact: true,
        ),
        systemPrompt: _retrySystemPrompt,
        sessionId: '$sessionId:retry-1',
        isOffline: isOffline,
        maxTokens: _retryMaxTokens,
        cancellationToken: cancellationToken,
      );
    }

    if (!result.isSuccessful) {
      final detail = result.errorMessage?.trim();
      throw StateError(
        detail == null || detail.isEmpty
            ? 'Workshop Reviewer inference did not complete successfully.'
            : 'Workshop Reviewer inference failed: $detail',
      );
    }

    if (!result.hasText) {
      throw StateError(
        'Workshop Reviewer returned no verdict.',
      );
    }

    final verdict = _gate.evaluate(
      session: session,
      responseText: result.text,
    );

    RuntimeEventLog.instance.emit(
      '[WORKSHOP_REVIEW_VERDICT] '
      'approved=${verdict.approved} '
      'summary_chars=${verdict.summary.length} '
      'findings=${verdict.findings.length} '
      'warnings=${verdict.warnings.length}',
    );

    return verdict;
  }

  String _buildPrompt(
    WorkspaceSession session, {
    String? implementationPlan,
    bool compact = false,
  }) {
    final request = session.context.request;
    final original = session.workspace.originalSnapshot;
    final current = session.workspace.snapshot;

    final fileChars = compact ? _retryFileChars : _primaryFileChars;
    final changes = <Map<String, Object?>>[
      for (final change in session.diff.files.take(compact ? 2 : 4))
        <String, Object?>{
          'path': change.path,
          'type': change.changeType.name,
          'before': _boundedNullable(original[change.path], fileChars),
          'after': _boundedNullable(current[change.path], fileChars),
        },
    ];

    final contextBudget =
        compact ? _retryContextChars : _primaryContextChars;
    final taskContext = request.context
        .map((item) => item.trim())
        .where(
          (item) =>
              item.isNotEmpty &&
              !item.startsWith('WORKSHOP_APPROVED_PROPOSAL:'),
        )
        .map((item) => _boundedText(item, contextBudget))
        .take(compact ? 2 : 4)
        .toList(growable: false);

    final projectedPlan = WorkshopTaskPlanProjection.project(
      implementationPlan,
    );
    final boundedPlan = projectedPlan.isEmpty ? null : projectedPlan;

    final payload = <String, Object?>{
      'requestId': request.id,
      'title': request.title,
      'instruction': request.instruction,
      'implementationPlan': boundedPlan,
      'targetFiles': request.targetFiles,
      'constraints': request.constraints,
      'context': taskContext,
      'changes': changes,
    };

    final prompt = '''
Review the staged Workshop change set below for correctness, regressions,
requirement compliance and unsafe or incomplete edits.

SCOPE RULE:
Judge ONLY the current task described by title, instruction, implementationPlan,
targetFiles and constraints. The implementationPlan is the Architect's bounded
plan for this task and is authoritative for the expected increment. The context
field is project background, not a demand to finish future project features in
this task. Do not reject a correct bounded increment solely because later
project capabilities are not implemented yet.

Workshop input JSON:
${jsonEncode(payload)}

Return ONLY one JSON object with this exact contract:
{
  "approved": true,
  "summary": "non-empty review summary",
  "findings": ["optional finding"],
  "warnings": ["optional warning"]
}

The "approved" field MUST be one JSON boolean: true or false. Never output a string, an alternatives list, or values joined by a separator.
Do not return markdown fences or any text outside the JSON object.
'''.trim();

    RuntimeEventLog.instance.emit(
      '[WORKSHOP_REVIEW_PROMPT] '
      'compact=$compact chars=${prompt.length} files=${changes.length} '
      'plan_chars=${boundedPlan?.length ?? 0}',
    );
    return prompt;
  }

  static bool _shouldRetryReviewer(
    WorkshopInferenceResult result, {
    CancellationToken? cancellationToken,
  }) {
    if (result.isSuccessful && result.hasText) {
      return false;
    }
    if (cancellationToken?.isCancelled == true ||
        result.terminalState == InferenceTerminalState.cancelled ||
        result.terminalState == InferenceTerminalState.modelUnavailable) {
      return false;
    }
    if (result.terminalState == InferenceTerminalState.timeout ||
        result.terminalState == InferenceTerminalState.failed) {
      return true;
    }
    final error = (result.errorMessage ?? '').toLowerCase();
    if (error.contains('stall') ||
        error.contains('timeout') ||
        error.contains('timed out') ||
        error.contains('generation')) {
      return true;
    }
    return !result.isSuccessful || !result.hasText;
  }

  static String _boundedText(String value, int maxChars) {
    final normalized = value.trim();
    if (normalized.length <= maxChars) {
      return normalized;
    }
    return '${normalized.substring(0, maxChars)}…';
  }

  static String? _boundedNullable(String? value, int maxChars) {
    if (value == null) {
      return null;
    }
    return _boundedText(value, maxChars);
  }

  static const String _systemPrompt =
      'You are the Reviewer brain of the Cantiere. Review only the supplied '
      'Workshop request and staged workspace diff. Do not use or assume '
      'Assistant chat memory or configuration. Return the required JSON '
      'verdict only.';

  static const String _retrySystemPrompt =
      'You are the Cantiere Reviewer retrying after a local runtime failure. '
      'Use only the compact bounded task and diff supplied. Decide only whether '
      'this current increment is correct and safe. Return the required JSON '
      'verdict only; do not use project-wide future requirements.';
}
