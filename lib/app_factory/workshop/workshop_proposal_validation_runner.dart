import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Runs the Cantiere validation stage against the current staged workspace.
///
/// Validation reuses [WorkshopStageRoleInference], so the stage is routed to
/// the existing Reviewer model assignment and shared runtime. It reads only
/// the active Workshop request and VirtualWorkspace diff; Assistant settings,
/// models, memory and conversation state are never consulted.
///
/// A valid verdict keeps the session in validation. A rejected verdict is
/// delegated to [WorkshopProposalValidationGate], which blocks the session.
/// This runner never approves apply and never mutates the real workspace.
final class WorkshopProposalValidationRunner {
  const WorkshopProposalValidationRunner({
    required WorkshopStageRoleInference inference,
    WorkshopProposalValidationGate gate = const WorkshopProposalValidationGate(),
  })  : _inference = inference,
        _gate = gate;

  final WorkshopStageRoleInference _inference;
  final WorkshopProposalValidationGate _gate;

  Future<WorkshopValidationVerdict> run({
    required WorkspaceSession session,
    String? implementationPlan,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    if (session.status != WorkspaceSessionStatus.validation) {
      throw StateError(
        'Workshop validation can only run while the workspace session is in '
        'validation. Current status: ${session.status.name}.',
      );
    }

    if (!session.hasChanges) {
      throw StateError('Workshop validation requires staged workspace changes.');
    }

    final result = await _inference.complete(
      stage: WorkshopStage.validation,
      prompt: _buildPrompt(
        session,
        implementationPlan: implementationPlan,
      ),
      systemPrompt: _systemPrompt,
      sessionId: 'workshop:validation:${session.context.request.id}',
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    if (!result.isSuccessful) {
      final detail = result.errorMessage?.trim();
      throw StateError(
        detail == null || detail.isEmpty
            ? 'Workshop validation inference did not complete successfully.'
            : 'Workshop validation inference failed: $detail',
      );
    }

    if (!result.hasText) {
      throw StateError('Workshop validation returned no verdict.');
    }

    final verdict = _gate.evaluate(
      session: session,
      responseText: result.text,
    );

    RuntimeEventLog.instance.emit(
      '[WORKSHOP_VALIDATION_VERDICT] '
      'valid=${verdict.valid} '
      'summary_chars=${verdict.summary.length} '
      'checks=${verdict.checks.length} '
      'warnings=${verdict.warnings.length}',
    );

    return verdict;
  }

  String _buildPrompt(
    WorkspaceSession session, {
    String? implementationPlan,
  }) {
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

    final normalizedPlan = implementationPlan?.trim();
    final boundedPlan =
        normalizedPlan == null || normalizedPlan.isEmpty
            ? null
            : normalizedPlan.length <= 4000
                ? normalizedPlan
                : normalizedPlan.substring(0, 4000);

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

    return '''
Validate the staged Workshop change set below before apply approval.
Check requirement compliance, internal consistency, regressions and whether
all staged edits are safe to hand to the explicit approval/apply gate.

SCOPE RULE:
Validate ONLY the current task described by title, instruction,
implementationPlan, targetFiles and constraints. The implementationPlan is the
Architect's bounded plan for this task and is authoritative for the expected
increment. The context field is project background. Missing future project
features must not invalidate a correct bounded increment unless they are
explicit requirements of this current task.

Workshop input JSON:
${jsonEncode(payload)}

Return ONLY one JSON object with this exact contract:
{
  "valid": true|false,
  "summary": "non-empty validation summary",
  "checks": ["optional completed check"],
  "warnings": ["optional warning"]
}

Do not return markdown fences or any text outside the JSON object.
'''.trim();
  }

  static const String _systemPrompt =
      'You are the validation brain of the Cantiere Reviewer. Validate only '
      'the supplied Workshop request and staged workspace diff. Do not use or '
      'assume Assistant chat memory or configuration. Return the required JSON '
      'verdict only. Never approve apply or mutate files.';
}
