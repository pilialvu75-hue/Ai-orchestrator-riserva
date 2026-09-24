import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
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

  Future<WorkshopReviewVerdict> run({
    required WorkspaceSession session,
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

    final result = await _inference.complete(
      stage: WorkshopStage.review,
      prompt: _buildPrompt(session),
      systemPrompt: _systemPrompt,
      sessionId: 'workshop:review:${session.context.request.id}',
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

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

  String _buildPrompt(WorkspaceSession session) {
    final request = session.context.request;
    final original = session.workspace.originalSnapshot;
    final current = session.workspace.snapshot;

    final changes = <Map<String, Object?>>[
      for (final change in session.diff.files)
        <String, Object?>{
          'path': change.path,
          'type': change.changeType.name,
          'before': original[change.path],
          'after': current[change.path],
        },
    ];

    final taskContext = request.context
        .map((item) => item.trim())
        .where(
          (item) =>
              item.isNotEmpty &&
              !item.startsWith('WORKSHOP_APPROVED_PROPOSAL:'),
        )
        .toList(growable: false);

    final payload = <String, Object?>{
      'requestId': request.id,
      'title': request.title,
      'instruction': request.instruction,
      'targetFiles': request.targetFiles,
      'constraints': request.constraints,
      'context': taskContext,
      'changes': changes,
    };

    return '''
Review the staged Workshop change set below for correctness, regressions,
requirement compliance and unsafe or incomplete edits.

SCOPE RULE:
Judge ONLY the current task described by title, instruction, targetFiles and
constraints. The context field is project background, not a demand to finish
future project features in this task. Do not reject a correct bounded increment
solely because later project capabilities are not implemented yet.

Workshop input JSON:
${jsonEncode(payload)}

Return ONLY one JSON object with this exact contract:
{
  "approved": true|false,
  "summary": "non-empty review summary",
  "findings": ["optional finding"],
  "warnings": ["optional warning"]
}

Do not return markdown fences or any text outside the JSON object.
'''.trim();
  }

  static const String _systemPrompt =
      'You are the Reviewer brain of the Cantiere. Review only the supplied '
      'Workshop request and staged workspace diff. Do not use or assume '
      'Assistant chat memory or configuration. Return the required JSON '
      'verdict only.';
}
