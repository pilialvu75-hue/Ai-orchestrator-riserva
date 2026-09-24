import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
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

  static const int _primaryMaxTokens = 256;
  static const int _retryMaxTokens = 192;
  static const int _primaryPlanChars = 1200;
  static const int _retryPlanChars = 700;
  static const int _primaryFileChars = 2400;
  static const int _retryFileChars = 1200;
  static const int _primaryContextChars = 320;
  static const int _retryContextChars = 160;

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

    final sessionId = 'workshop:validation:${session.context.request.id}';
    var didRetry = false;
    var result = await _inference.complete(
      stage: WorkshopStage.validation,
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

    if (_shouldRetryValidation(
      result,
      cancellationToken: cancellationToken,
    )) {
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_VALIDATION_RETRY] '
        'attempt=2 terminal=${result.terminalState?.name ?? 'none'} '
        'chars=${result.text.length}',
      );

      didRetry = true;
      result = await _inference.complete(
        stage: WorkshopStage.validation,
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
            ? 'Workshop validation inference did not complete successfully.'
            : 'Workshop validation inference failed: $detail',
      );
    }

    if (!result.hasText) {
      throw StateError('Workshop validation returned no verdict.');
    }

    WorkshopValidationVerdict verdict;
    try {
      verdict = _gate.evaluate(
        session: session,
        responseText: result.text,
      );
    } on FormatException catch (error) {
      if (didRetry ||
          cancellationToken?.isCancelled == true ||
          !_isRetryableValidationFormatException(error)) {
        rethrow;
      }

      RuntimeEventLog.instance.emit(
        '[WORKSHOP_VALIDATION_RETRY] '
        'attempt=2 terminal=${result.terminalState?.name ?? 'none'} '
        'chars=${result.text.length}',
      );

      didRetry = true;
      result = await _inference.complete(
        stage: WorkshopStage.validation,
        prompt: _buildPrompt(
          session,
          implementationPlan: implementationPlan,
          compact: true,
        ),
        systemPrompt: _malformedOutputRetrySystemPrompt,
        sessionId: '$sessionId:retry-format-1',
        isOffline: isOffline,
        maxTokens: _retryMaxTokens,
        cancellationToken: cancellationToken,
      );

      if (!result.isSuccessful) {
        final detail = result.errorMessage?.trim();
        throw StateError(
          detail == null || detail.isEmpty
              ? 'Workshop validation retry did not complete successfully.'
              : 'Workshop validation retry failed: $detail',
        );
      }
      if (!result.hasText) {
        throw StateError('Workshop validation retry returned no verdict.');
      }

      verdict = _gate.evaluate(
        session: session,
        responseText: result.text,
      );
    }

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

    final normalizedPlan = implementationPlan?.trim();
    final planBudget = compact ? _retryPlanChars : _primaryPlanChars;
    final boundedPlan =
        normalizedPlan == null || normalizedPlan.isEmpty
            ? null
            : _boundedText(normalizedPlan, planBudget);

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
  "valid": true,
  "summary": "non-empty validation summary",
  "checks": ["optional completed check"],
  "warnings": ["optional warning"]
}

The "valid" field MUST be one JSON boolean: true or false. Never output a string, an alternatives list, or values joined by a separator.
Do not return markdown fences or any text outside the JSON object.
'''.trim();

    RuntimeEventLog.instance.emit(
      '[WORKSHOP_VALIDATION_PROMPT] '
      'compact=$compact chars=${prompt.length} files=${changes.length} '
      'plan_chars=${boundedPlan?.length ?? 0}',
    );
    return prompt;
  }

  static bool _isRetryableValidationFormatException(
    FormatException error,
  ) {
    if (error.source != null || error.offset != null) {
      return true;
    }
    return error.message.toString() ==
        'Workshop validation field "summary" is required.';
  }

  static bool _shouldRetryValidation(
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
      'You are the validation brain of the Cantiere Reviewer. Validate only '
      'the supplied Workshop request and staged workspace diff. Do not use or '
      'assume Assistant chat memory or configuration. Return the required JSON '
      'verdict only. Never approve apply or mutate files.';

  static const String _retrySystemPrompt =
      'You are the Cantiere validation reviewer retrying after a local runtime '
      'failure. Use only the compact bounded task and diff supplied. Validate '
      'only this current increment. Return the required JSON verdict only; '
      'never approve apply or mutate files.';

  static const String _malformedOutputRetrySystemPrompt =
      'You are the Cantiere validation reviewer retrying because the previous '
      'structured verdict was incomplete or malformed. Use only the compact '
      'bounded task and staged diff supplied. Return exactly one JSON object '
      'with a boolean "valid", a non-empty string "summary", and optional '
      'string arrays "checks" and "warnings". A true/false verdict remains '
      'authoritative; do not change it merely to pass the gate. Never approve '
      'apply or mutate files.';
}
