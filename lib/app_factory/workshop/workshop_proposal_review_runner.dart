import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
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
  static const Duration _retryFirstTokenTimeout = Duration(seconds: 75);
  static const int _filesPerBatch = 2;
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

    final changes = session.diff.files.toList(growable: false)
      ..sort((left, right) => left.path.compareTo(right.path));
    if (changes.isEmpty) {
      throw StateError(
        'Workshop Reviewer requires a non-empty staged diff.',
      );
    }

    final coverage = _coverageManifest(session);
    final batchCount =
        (changes.length + _filesPerBatch - 1) ~/ _filesPerBatch;
    final summaries = <String>[];
    final findings = <String>[];
    final warnings = <String>[];
    final reviewedPaths = <String>{};

    for (var batchIndex = 0; batchIndex < batchCount; batchIndex += 1) {
      final start = batchIndex * _filesPerBatch;
      final proposedEnd = start + _filesPerBatch;
      final end = proposedEnd < changes.length ? proposedEnd : changes.length;
      final batch = changes.sublist(start, end);

      final verdict = await _reviewBatch(
        session: session,
        implementationPlan: implementationPlan,
        batch: batch,
        batchIndex: batchIndex,
        batchCount: batchCount,
        coverage: coverage,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );

      final currentCoverage = _coverageManifest(session);
      if (currentCoverage.fingerprint != coverage.fingerprint) {
        throw StateError(
          'Workshop review invalidated because the staged diff changed while '
          'review was in progress. Restart review for the new diff.',
        );
      }

      reviewedPaths.addAll(batch.map((change) => change.path));
      summaries.add(verdict.summary);
      findings.addAll(verdict.findings);
      warnings.addAll(verdict.warnings);

      if (!verdict.approved) {
        _gate.applyVerdict(session: session, verdict: verdict);
        return verdict;
      }
    }

    final expectedPaths = changes.map((change) => change.path).toSet();
    if (reviewedPaths.length != expectedPaths.length ||
        !reviewedPaths.containsAll(expectedPaths)) {
      throw StateError(
        'Workshop review coverage is incomplete; aggregate approval denied.',
      );
    }

    final aggregate = WorkshopReviewVerdict(
      approved: true,
      summary: summaries.length == 1
          ? summaries.single
          : 'All ${summaries.length} review batches approved: '
              '${summaries.join(' | ')}',
      findings: List<String>.unmodifiable(findings),
      warnings: List<String>.unmodifiable(warnings),
    );

    _gate.applyVerdict(session: session, verdict: aggregate);

    RuntimeEventLog.instance.emit(
      '[WORKSHOP_REVIEW_VERDICT] '
      'approved=true files=${changes.length} batches=$batchCount '
      'coverage=${coverage.fingerprint} '
      'findings=${aggregate.findings.length} '
      'warnings=${aggregate.warnings.length}',
    );

    return aggregate;
  }

  Future<WorkshopReviewVerdict> _reviewBatch({
    required WorkspaceSession session,
    required String? implementationPlan,
    required List<GitWorkspaceFileChange> batch,
    required int batchIndex,
    required int batchCount,
    required _WorkshopReviewCoverageManifest coverage,
    required bool isOffline,
    required CancellationToken? cancellationToken,
  }) async {
    final requestId = session.context.request.id;
    final batchSuffix = batchCount == 1
        ? ''
        : ':batch-${batchIndex + 1}-of-$batchCount';
    final sessionId = 'workshop:review:$requestId$batchSuffix';

    var result = await _inference.complete(
      stage: WorkshopStage.review,
      prompt: _buildPrompt(
        session,
        implementationPlan: implementationPlan,
        batch: batch,
        batchIndex: batchIndex,
        batchCount: batchCount,
        coverage: coverage,
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
        'batch=${batchIndex + 1}/$batchCount '
        'attempt=2 terminal=${result.terminalState?.name ?? 'none'} '
        'chars=${result.text.length}',
      );

      result = await _inference.completeWithFirstTokenTimeout(
        stage: WorkshopStage.review,
        prompt: _buildPrompt(
          session,
          implementationPlan: implementationPlan,
          batch: batch,
          batchIndex: batchIndex,
          batchCount: batchCount,
          coverage: coverage,
          compact: true,
        ),
        firstTokenTimeout: _retryFirstTokenTimeout,
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

    final verdict = _gate.decode(result.text);

    RuntimeEventLog.instance.emit(
      '[WORKSHOP_REVIEW_BATCH_VERDICT] '
      'batch=${batchIndex + 1}/$batchCount '
      'approved=${verdict.approved} files=${batch.length} '
      'coverage=${coverage.fingerprint}',
    );

    return verdict;
  }

  String _buildPrompt(
    WorkspaceSession session, {
    required List<GitWorkspaceFileChange> batch,
    required int batchIndex,
    required int batchCount,
    required _WorkshopReviewCoverageManifest coverage,
    String? implementationPlan,
    bool compact = false,
  }) {
    final request = session.context.request;
    final original = session.workspace.originalSnapshot;
    final current = session.workspace.snapshot;

    final fileChars = compact ? _retryFileChars : _primaryFileChars;
    final changes = <Map<String, Object?>>[
      for (final change in batch)
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
      'targetFilesPolicy': request.targetFiles.isEmpty
          ? 'unspecified_for_initial_create_task'
          : 'explicit_scope',
      'constraints': request.constraints,
      'context': taskContext,
      'coverageManifest': coverage.toJson(),
      'reviewBatch': <String, Object?>{
        'index': batchIndex + 1,
        'count': batchCount,
        'paths': batch.map((change) => change.path).toList(growable: false),
      },
      'changes': changes,
    };

    final prompt = '''
Review the staged Workshop change batch below for correctness, regressions,
requirement compliance and unsafe or incomplete edits.

COVERAGE RULE:
This is batch ${batchIndex + 1} of $batchCount. Review every file in
reviewBatch.paths. coverageManifest lists the complete staged diff using
content fingerprints. Approve only this supplied batch. The runner will grant a
global approval only after every expected path has an approved batch verdict
against the same coverage fingerprint. Never assume an omitted staged file was
reviewed.

SCOPE RULE:
Judge ONLY the current task described by title, instruction, implementationPlan,
targetFiles and constraints.

CONTRACT PRECEDENCE:
1. The explicit task instruction and explicit constraints are authoritative.
   UI LITERAL FIDELITY is part of requirement compliance: explicit visible
   strings, labels, titles, units and symbols must remain verbatim unless the
   task explicitly authorizes renaming. Reject gratuitous substitutions such as
   requested "+" becoming "+1".
2. implementationPlan is the exact bounded Architect projection supplied to
   the Engineer. It is model-authored guidance and must not override or
   contradict the explicit task. Do not infer requirements from omitted parts
   of the unavailable full Architect response.
3. targetFiles is a hard restriction only when targetFilesPolicy is
   "explicit_scope". When targetFilesPolicy is
   "unspecified_for_initial_create_task", an empty targetFiles list means the
   initial create task did not preselect files; it does NOT mean "no files are
   allowed" and is not by itself a mismatch.

If implementationPlan conflicts with the explicit instruction, judge the staged
change against the explicit task and constraints. The context field is project
background, not a demand to finish future project features in this task. Do not
reject a correct bounded increment solely because later project capabilities
are not implemented yet or because initial targetFiles were intentionally
unspecified.

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
      'compact=$compact batch=${batchIndex + 1}/$batchCount '
      'chars=${prompt.length} files=${changes.length} '
      'coverage=${coverage.fingerprint} '
      'plan_chars=${boundedPlan?.length ?? 0}',
    );
    return prompt;
  }

  static _WorkshopReviewCoverageManifest _coverageManifest(
    WorkspaceSession session,
  ) {
    final original = session.workspace.originalSnapshot;
    final current = session.workspace.snapshot;
    final changes = session.diff.files.toList(growable: false)
      ..sort((left, right) => left.path.compareTo(right.path));

    final files = <Map<String, Object?>>[
      for (final change in changes)
        <String, Object?>{
          'path': change.path,
          'type': change.changeType.name,
          'before': _fingerprintNullable(original[change.path]),
          'after': _fingerprintNullable(current[change.path]),
        },
    ];
    final fingerprint = _fingerprint(jsonEncode(files));
    return _WorkshopReviewCoverageManifest(
      fingerprint: fingerprint,
      files: List<Map<String, Object?>>.unmodifiable(files),
    );
  }

  static String _fingerprintNullable(String? value) {
    if (value == null) {
      return 'null';
    }
    return _fingerprint('value:$value');
  }

  static String _fingerprint(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
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

final class _WorkshopReviewCoverageManifest {
  const _WorkshopReviewCoverageManifest({
    required this.fingerprint,
    required this.files,
  });

  final String fingerprint;
  final List<Map<String, Object?>> files;

  Map<String, Object?> toJson() => <String, Object?>{
        'fingerprint': fingerprint,
        'files': files,
      };
}

