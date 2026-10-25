import 'dart:convert';
import 'package:ai_orchestrator/app_factory/workshop/workshop_source_prompt_policy.dart';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_plan_projection.dart';
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
    WorkshopSourcePromptPolicy promptPolicy = const WorkshopSourcePromptPolicy(),
  })  : _inference = inference,
        _promptPolicy = promptPolicy,
        _gate = gate;

  final WorkshopStageRoleInference _inference;
  final WorkshopProposalValidationGate _gate;
  final WorkshopSourcePromptPolicy _promptPolicy;

  static const int _primaryMaxTokens = 256;
  static const int _retryMaxTokens = 192;
  int get _primaryFileChars => _promptPolicy.primaryFileChars;
  int get _retryFileChars => _promptPolicy.retryFileChars;
  static const int _primaryContextChars = 320;
  static const int _retryContextChars = 160;
  static const int _filesPerBatch = 2;
  int get _maxHolisticPromptChars => _promptPolicy.maxPromptChars;

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

    // Each bounded batch covers two files, never silently ignoring the tail.
    final changes = session.diff.files.toList(growable: false)
      ..sort((left, right) => left.path.compareTo(right.path));
    if (changes.isEmpty) {
      throw StateError('Workshop validation requires a non-empty staged diff.');
    }
    final originals = session.workspace.originalSnapshot;
    final staged = session.workspace.snapshot;
    final before = <String, String?>{
      for (final change in changes) change.path: originals[change.path],
    };
    final after = <String, String?>{
      for (final change in changes) change.path: staged[change.path],
    };
    final batchCount = (changes.length + _filesPerBatch - 1) ~/ _filesPerBatch;
    final summaries = <String>[];
    final checks = <String>[];
    final warnings = <String>[];
    final covered = <String>{};
    for (var batchIndex = 0; batchIndex < batchCount; batchIndex++) {
      _assertUnchanged(session, changes, before, after);
      final start = batchIndex * _filesPerBatch;
      final end = start + _filesPerBatch < changes.length
          ? start + _filesPerBatch
          : changes.length;
      final batch = changes.sublist(start, end);
      final verdict = await _validateBatch(
        session: session,
        batch: batch,
        batchIndex: batchIndex,
        batchCount: batchCount,
        implementationPlan: implementationPlan,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
      _assertUnchanged(session, changes, before, after);
      covered.addAll(batch.map((change) => change.path));
      if (!verdict.valid) return verdict;
      summaries.add(verdict.summary);
      checks.addAll(verdict.checks);
      warnings.addAll(verdict.warnings);
    }
    if (covered.length != changes.length) {
      throw StateError('Workshop validation file coverage is incomplete.');
    }
    // Every pair of per-file groups is checked together: pairwise complete
    // across groups, while each local-model prompt contains at most four files.
    if (batchCount > 1) {
      final groups = <List<GitWorkspaceFileChange>>[
        for (var start = 0; start < changes.length; start += _filesPerBatch)
          changes.sublist(
            start,
            start + _filesPerBatch < changes.length
                ? start + _filesPerBatch
                : changes.length,
          ),
      ];
      final pairCount = (groups.length * (groups.length - 1)) ~/ 2;
      var pairIndex = 0;
      for (var left = 0; left < groups.length; left++) {
        for (var right = left + 1; right < groups.length; right++) {
          _assertUnchanged(session, changes, before, after);
          final window = <GitWorkspaceFileChange>[
            ...groups[left],
            ...groups[right],
          ];
          final combined = await _validateBatch(
            session: session,
            batch: window,
            batchIndex: pairIndex,
            batchCount: pairCount,
            holistic: true,
            implementationPlan: implementationPlan,
            isOffline: isOffline,
            cancellationToken: cancellationToken,
          );
          _assertUnchanged(session, changes, before, after);
          if (!combined.valid) return combined;
          summaries.add(combined.summary);
          checks.addAll(combined.checks);
          warnings.addAll(combined.warnings);
          pairIndex++;
        }
      }
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_VALIDATION_CROSS_FILE] windows=$pairCount '
        'groups=${groups.length} files=${changes.length}',
      );
    }
    RuntimeEventLog.instance.emit(
      '[WORKSHOP_VALIDATION_COVERAGE] '
      'files=${covered.length} batches=$batchCount',
    );
    return WorkshopValidationVerdict(
      valid: true,
      summary: summaries.length == 1
          ? summaries.single
          : 'All $batchCount validation batches passed: ${summaries.join(' | ')}',
      checks: List<String>.unmodifiable(checks),
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  void _assertUnchanged(
    WorkspaceSession session,
    List<GitWorkspaceFileChange> expected,
    Map<String, String?> originals,
    Map<String, String?> staged,
  ) {
    final current = session.diff.files.toList(growable: false)
      ..sort((left, right) => left.path.compareTo(right.path));
    if (current.length != expected.length) {
      throw StateError('Workshop validation invalidated: staged diff changed.');
    }
    final before = session.workspace.originalSnapshot;
    final after = session.workspace.snapshot;
    for (var i = 0; i < expected.length; i++) {
      final path = expected[i].path;
      if (current[i].path != path ||
          current[i].changeType != expected[i].changeType ||
          before[path] != originals[path] ||
          after[path] != staged[path]) {
        throw StateError('Workshop validation invalidated: staged diff changed.');
      }
    }
  }

  Future<WorkshopValidationVerdict> _validateBatch({
    required WorkspaceSession session,
    required List<GitWorkspaceFileChange> batch,
    required int batchIndex,
    required int batchCount,
    bool holistic = false,
    String? implementationPlan,
    required bool isOffline,
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

    final sessionId = 'workshop:validation:${session.context.request.id}'
        '${holistic ? ':holistic-${batchIndex + 1}-of-$batchCount' : batchCount == 1 ? '' : ':batch-${batchIndex + 1}-of-$batchCount'}';
    var didRetry = false;
    var result = await _inference.complete(
      stage: WorkshopStage.validation,
      prompt: _buildPrompt(
        session,
        batch: batch,
        batchIndex: batchIndex,
        batchCount: batchCount,

        holistic: holistic,
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
          batch: batch,
          batchIndex: batchIndex,
          batchCount: batchCount,

          holistic: holistic,
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
          batch: batch,
          batchIndex: batchIndex,
          batchCount: batchCount,

          holistic: holistic,
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
    required List<GitWorkspaceFileChange> batch,
    required int batchIndex,
    required int batchCount,
    String? implementationPlan,
    bool compact = false,
    bool holistic = false,
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
          'before': holistic
              ? _crossFileExcerpt(original[change.path])
              : _boundedNullable(original[change.path], fileChars),
          'after': holistic
              ? _crossFileExcerpt(current[change.path])
              : _boundedNullable(current[change.path], fileChars),
          if (holistic) 'apiSurface': _apiSurface(current[change.path]),
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
      'validationBatch': <String, int>{
        'index': batchIndex + 1,
        'count': batchCount,
        'filesInBatch': changes.length,
      },
      'changes': changes,
    };

    final prompt = holistic
        ? '''
FINAL CROSS-FILE CONSISTENCY CHECK — READ-ONLY.
All per-file batches passed, but cross-file safety is not yet established.
Examine EVERY staged path, imports/exports and apiSurface definitions together.
Confirm producers and consumers expose compatible symbols and the original owner
instruction/constraints remain satisfied. before/after may be SOURCE EXCERPTS,
not full files. Reject if missing source prevents verifying cross-file uses;
never assume an unseen definition exists. Baseline Flutter scaffold is provided.
This is never permission to apply, merge or add unrelated future requirements.

Workshop input JSON:
${jsonEncode(payload)}

Return JSON ONLY: {"valid":false,"summary":"reason","checks":[],"warnings":[]}
Set valid to boolean based on evidence; always provide a nonempty summary.
'''
            .trim()
        : '''
Validate the staged Workshop change set below before apply approval.
Check requirement compliance, internal consistency, regressions and whether
all staged edits are safe to hand to the explicit approval/apply gate.

SCOPE RULE:
Validate ONLY the current task described by title, instruction,
implementationPlan, targetFiles and constraints.

CONTRACT PRECEDENCE:
1. The explicit task instruction and explicit constraints are authoritative.
   UI LITERAL FIDELITY is a validation requirement: explicit visible strings,
   labels, titles, units and symbols must remain verbatim unless the task
   explicitly authorizes renaming. A substitution such as requested "+"
   becoming "+1" is a requirement mismatch, not an equivalent implementation.
2. implementationPlan is the exact bounded Architect projection supplied to
   the Engineer. It is model-authored guidance and must not override or
   contradict the explicit task. Treat plan items as requirements for THIS
   validation only when the explicit current task instruction or constraints
   also require them. In particular, do NOT invalidate the current staged
   increment for missing tests, documentation, cleanup, validation work or
   follow-up features mentioned only in implementationPlan; those may belong
   to later bounded tasks. Do not infer requirements from omitted parts of the
   unavailable full Architect response.
3. targetFiles is a hard restriction only when targetFilesPolicy is
   "explicit_scope". When targetFilesPolicy is
   "unspecified_for_initial_create_task", an empty targetFiles list means the
   initial create task did not preselect files; it does NOT mean "no files are
   allowed" and is not by itself a validation failure.
4. GENERIC FLUTTER SCAFFOLD CONTRACT: the remote/local Cantiere builder supplies
   the baseline Flutter project configuration (including pubspec.yaml and the
   platform scaffold) when the staged task only contributes app source. Do NOT
   invalidate a create task merely because pubspec.yaml is absent from the
   staged diff or because the task did not separately validate baseline
   scaffold configuration. Require a pubspec.yaml change/validation only when
   this task explicitly changes dependencies, assets, package metadata, SDK
   constraints, or other project configuration, or when staged source imports a
   third-party package that requires a declaration.

If implementationPlan conflicts with the explicit instruction, validate the
staged change against the explicit task and constraints. The context field is
project background. Missing future project features must not invalidate a
correct bounded increment unless they are explicit requirements of this current
task.

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

    if (holistic && prompt.length > _maxHolisticPromptChars) {
      throw StateError(
        'Workshop holistic validation exceeds bounded context; '
        'cross-file safety was not verified.',
      );
    }
    RuntimeEventLog.instance.emit(
      '[WORKSHOP_VALIDATION_PROMPT] '
      'compact=$compact holistic=$holistic chars=${prompt.length} files=${changes.length} '
      'plan_chars=${boundedPlan?.length ?? 0}',
    );
    return prompt;
  }

  // Cross-file witness includes callable declarations AND their call sites
  // anywhere in the file, not just the beginning/end source excerpt.
  // Missing detail is never silently promoted to a valid holistic verdict.
  static String? _crossFileExcerpt(String? raw) {
    if (raw == null) return null;
    if (raw.length <= 320) return raw;
    return '${raw.substring(0, 160)}\n...[source omitted]...\n'
        '${raw.substring(raw.length - 135)}';
  }

  static String _apiSurface(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final lines = <String>[];
    // Any custom return type is allowed. Capture declaration and invocation
    // lines from the full source, including code in the omitted middle.
    final callable = RegExp(
      r'^(?:[\w<>?,.\[\] ]+\s+)?[a-zA-Z_]\w*\s*\([^\n]*\)'
      r'|\b[a-zA-Z_]\w*\.[a-zA-Z_]\w*\s*\(',
    );
    final directive = RegExp(
      r'^(?:import |export |part |library |class |abstract class |'
      r'enum |mixin |typedef |extension )',
    );
    for (final sourceLine in raw.split('\n')) {
      final line = sourceLine.trim();
      if (line.isEmpty || line.startsWith('//')) continue;
      if (directive.hasMatch(line) || callable.hasMatch(line)) {
        lines.add(line);
      }
    }
    // Do not silently drop an API/call-site line; it could be the entire
    // reason for incompatibility. A larger witness cannot receive PASS.
    final joined = lines.join('\n');
    if (joined.length > 1400) {
      throw StateError(
        'Workshop cross-file API witness exceeds bounded context; '
        'cannot verify compatibility without additional evidence.',
      );
    }
    return joined;
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
