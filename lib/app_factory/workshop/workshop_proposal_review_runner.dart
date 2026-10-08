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
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';

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
  WorkshopProposalReviewRunner({
    required WorkshopStageRoleInference inference,
    WorkshopProposalReviewGate gate = const WorkshopProposalReviewGate(),
    Future<bool> Function(CancellationToken? cancellationToken)?
        memoryRecoveryWaiter,
  })  : _inference = inference,
        _gate = gate,
        _memoryRecoveryWaiter =
            memoryRecoveryWaiter ?? _waitForRuntimeMemoryRecovery;

  final WorkshopStageRoleInference _inference;
  final WorkshopProposalReviewGate _gate;
  final Future<bool> Function(CancellationToken? cancellationToken)
      _memoryRecoveryWaiter;

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
    final batchCount = (changes.length + _filesPerBatch - 1) ~/ _filesPerBatch;
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
    final batchSuffix =
        batchCount == 1 ? '' : ':batch-${batchIndex + 1}-of-$batchCount';
    final sessionId = 'workshop:review:$requestId$batchSuffix';

    final result = await _inference.complete(
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

    var retryReason = 'runtime';
    if (!_shouldRetryReviewer(
      result,
      cancellationToken: cancellationToken,
    )) {
      try {
        return _decodeBatchResult(
          result: result,
          batchIndex: batchIndex,
          batchCount: batchCount,
          fileCount: batch.length,
          coverage: coverage,
          cancellationToken: cancellationToken,
        );
      } on FormatException {
        if (cancellationToken?.isCancelled == true) rethrow;
        retryReason = 'malformed_output';
      }
    }

    if (_isCriticalMemoryFailure(result)) {
      retryReason = 'critical_memory';
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_REVIEW_MEMORY_RECOVERY] '
        'batch=${batchIndex + 1}/$batchCount action=wait',
      );
      final recoveredMemory =
          await _memoryRecoveryWaiter(cancellationToken);
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_REVIEW_MEMORY_RECOVERY] '
        'batch=${batchIndex + 1}/$batchCount '
        'action=${recoveredMemory ? 'resume' : 'stop'}',
      );
      if (!recoveredMemory) {
        return _decodeBatchResult(
          result: result,
          batchIndex: batchIndex,
          batchCount: batchCount,
          fileCount: batch.length,
          coverage: coverage,
          cancellationToken: cancellationToken,
        );
      }
      retryReason = 'critical_memory_recovered';
    }

    RuntimeEventLog.instance.emit(
      '[WORKSHOP_REVIEW_RETRY] '
      'batch=${batchIndex + 1}/$batchCount '
      'attempt=2 reason=$retryReason '
      'terminal=${result.terminalState?.name ?? 'none'} '
      'chars=${result.text.length}',
    );

    // Runtime and format failures share ONE retry budget per batch. A second
    // invalid response is terminal; no approval or partial JSON is invented.
    final recovered = await _inference.completeWithFirstTokenTimeout(
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
      temperature: 0.1,
      cancellationToken: cancellationToken,
    );

    return _decodeBatchResult(
      result: recovered,
      batchIndex: batchIndex,
      batchCount: batchCount,
      fileCount: batch.length,
      coverage: coverage,
      cancellationToken: cancellationToken,
    );
  }

  WorkshopReviewVerdict _decodeBatchResult({
    required WorkshopInferenceResult result,
    required int batchIndex,
    required int batchCount,
    required int fileCount,
    required _WorkshopReviewCoverageManifest coverage,
    required CancellationToken? cancellationToken,
  }) {
    if (cancellationToken?.isCancelled == true) {
      throw StateError('Workshop Reviewer was cancelled.');
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

    final WorkshopReviewVerdict verdict;
    try {
      verdict = _gate.decode(result.text);
    } on FormatException {
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_REVIEW_JSON] '
        'batch=${batchIndex + 1}/$batchCount '
        'rejected=invalid_verdict chars=${result.text.length}',
      );
      rethrow;
    }

    RuntimeEventLog.instance.emit(
      '[WORKSHOP_REVIEW_BATCH_VERDICT] '
      'batch=${batchIndex + 1}/$batchCount '
      'approved=${verdict.approved} files=$fileCount '
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
    final isBuildRepair =
        request.instruction.trimLeft().startsWith('BUILD REPAIR ATTEMPT:');
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

    final contextBudget = compact ? _retryContextChars : _primaryContextChars;
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
      'buildRepair': isBuildRepair,
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

    final prompt = compact
        ? '''
Review only the current staged batch. Check correctness, regressions, unsafe or
incomplete edits. Review every reviewBatch.paths entry against the unchanged
coverageManifest; other batches are not approved by this verdict.
The explicit instruction and constraints are authoritative, including literal
UI strings, labels, titles, units and symbols. Architect implementationPlan is
guidance only: do not add future features, tests or documentation requirements
from it or from background context. targetFiles is a hard allowlist only for
explicit_scope; an empty list for unspecified_for_initial_create_task is not
itself a rejection. The builder supplies the baseline Flutter scaffold and
pubspec.yaml. Require configuration changes only for explicit configuration
work or added dependencies/assets. When buildRepair is true, judge the staged
edit against the cited build failure and preserved product behavior. Removing
an unused import, dead code, or another analyzer-triggering artifact is not a
regression merely because that source text existed before. If rejecting an
import removal, identify the concrete symbol or explicit required behavior that
the after-content can no longer satisfy. Reject if the supplied evidence cannot
establish correctness; never assume omitted content is safe.

Workshop input JSON:
${jsonEncode(payload)}

Return one complete JSON object only, without fences or prose:
{"approved":false,"summary":"brief reason","findings":[],"warnings":[]}
approved must be a boolean based on your review; summary must be non-empty.
findings and warnings must be lists of strings. Keep the verdict concise.
'''
            .trim()
        : '''
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
   contradict the explicit task. Treat plan items as requirements for THIS
   review only when the explicit current task instruction or constraints also
   require them. In particular, do NOT reject the current staged increment for
   missing tests, documentation, cleanup, validation work or follow-up features
   mentioned only in implementationPlan; those may belong to later bounded
   tasks. Do not infer requirements from omitted parts of the unavailable full
   Architect response.
3. targetFiles is a hard restriction only when targetFilesPolicy is
   "explicit_scope". When targetFilesPolicy is
   "unspecified_for_initial_create_task", an empty targetFiles list means the
   initial create task did not preselect files; it does NOT mean "no files are
   allowed" and is not by itself a mismatch.
4. GENERIC FLUTTER SCAFFOLD CONTRACT: the remote/local Cantiere builder supplies
   the baseline Flutter project configuration (including pubspec.yaml and the
   platform scaffold) when the staged task only contributes app source. Do NOT
   reject a create task merely because pubspec.yaml is absent from the staged
   diff or because the task did not separately validate baseline scaffold
   configuration. Require a pubspec.yaml change/validation only when this task
   explicitly changes dependencies, assets, package metadata, SDK constraints,
   or other project configuration, or when staged source imports a third-party
   package that requires a declaration.
5. BUILD REPAIR SEMANTICS: when buildRepair is true, this task exists to repair
   the concrete formatter/analyzer/test/build failure carried in the explicit
   instruction. Judge semantic behavior and compile/analyzer correctness, not
   textual preservation of the previous source. Removing an unused import,
   dead code, or another analyzer-triggering artifact is not a regression by
   itself. If rejecting an import removal, identify the concrete symbol still
   needed by the after-content or the explicit required product behavior that
   would be lost. Never require keeping a source line solely because it existed
   before the repair.

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
'''
            .trim();

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

  static bool _isCriticalMemoryFailure(
    WorkshopInferenceResult result,
  ) {
    final error = (result.errorMessage ?? '').toLowerCase();
    return error.contains('stage=critical_memory') ||
        error.contains('reason=critical_memory');
  }

  static Future<bool> _waitForRuntimeMemoryRecovery(
    CancellationToken? cancellationToken,
  ) {
    return ResourceMonitor.instance.waitForNonCritical(
      isCancelled: () => cancellationToken?.isCancelled == true,
    );
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
      'You are the Cantiere Reviewer retrying after a runtime or invalid-verdict failure. '
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
