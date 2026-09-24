import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_workspace_stager.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Runs the Cantiere Engineer against an initialized Workshop workspace and
/// stages the resulting structured proposal in the existing VirtualWorkspace.
///
/// This bridge reuses [WorkshopStageRoleInference], so implementation is
/// routed to the existing Engineer role/model assignment and shared runtime.
/// It reads only the active Workshop request, workspace snapshot and optional
/// Cantiere preflight output; Assistant configuration, model selection, memory
/// and conversation state are never consulted.
///
/// A successful Engineer response is decoded and staged through
/// [WorkshopProposalWorkspaceStager]. Real repository writes, approval, commit,
/// push and Pull Request creation remain outside this runner.
final class WorkshopProposalImplementationRunner {
  const WorkshopProposalImplementationRunner({
    required WorkshopStageRoleInference inference,
    WorkshopProposalWorkspaceStager stager =
        const WorkshopProposalWorkspaceStager(),
  })  : _inference = inference,
        _stager = stager;

  final WorkshopStageRoleInference _inference;
  final WorkshopProposalWorkspaceStager _stager;

  static const int _primaryMaxTokens = 640;
  static const int _retryMaxTokens = 512;
  static const int _malformedOutputRetryMaxTokens = 768;
  static const int _primaryArchitectChars = 900;
  static const int _retryArchitectChars = 600;
  static const int _primaryWorkspaceChars = 1800;
  static const int _retryWorkspaceChars = 900;
  static const int _primaryContextChars = 360;
  static const int _retryContextChars = 220;
  static const int _primaryConstraintChars = 360;
  static const int _retryConstraintChars = 220;

  Future<WorkshopChangeProposal> run({
    required WorkspaceSession session,
    WorkshopPreflightInferenceResult? preflight,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    _validateSession(session, preflight: preflight);

    final sessionId =
        'workshop:implementation:${session.context.request.id}';

    var result = await _inference.complete(
      stage: WorkshopStage.implementation,
      prompt: _buildPrompt(
        session,
        preflight: preflight,
      ),
      systemPrompt: _systemPrompt,
      sessionId: sessionId,
      isOffline: isOffline,
      maxTokens: _primaryMaxTokens,
      cancellationToken: cancellationToken,
    );

    var didRetry = false;
    if (_shouldRetryEngineer(
      result,
      cancellationToken: cancellationToken,
    )) {
      didRetry = true;
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_ENGINEER_RETRY] '
        'request=${session.context.request.id} '
        'attempt=2 reason=runtime terminal=${result.terminalState?.name ?? 'none'}',
      );

      result = await _inference.complete(
        stage: WorkshopStage.implementation,
        prompt: _buildPrompt(
          session,
          preflight: preflight,
          compact: true,
        ),
        systemPrompt: _retrySystemPrompt,
        sessionId: '$sessionId:retry-1',
        isOffline: isOffline,
        maxTokens: _retryMaxTokens,
        cancellationToken: cancellationToken,
      );
    }

    try {
      return _stageResult(session: session, result: result);
    } on FormatException catch (error) {
      if (didRetry ||
          cancellationToken?.isCancelled == true ||
          !_isJsonSyntaxFormatException(error)) {
        rethrow;
      }

      RuntimeEventLog.instance.emit(
        '[WORKSHOP_ENGINEER_RETRY] '
        'request=${session.context.request.id} '
        'attempt=2 reason=malformed_output '
        'terminal=${result.terminalState?.name ?? 'none'} '
        'chars=${result.text.length}',
      );

      final recovered = await _inference.complete(
        stage: WorkshopStage.implementation,
        prompt: _buildPrompt(
          session,
          preflight: preflight,
          compact: true,
        ),
        systemPrompt: _malformedOutputRetrySystemPrompt,
        sessionId: '$sessionId:retry-malformed-1',
        isOffline: isOffline,
        maxTokens: _malformedOutputRetryMaxTokens,
        cancellationToken: cancellationToken,
      );

      return _stageResult(session: session, result: recovered);
    }
  }

  /// Runs the Engineer from an authoritative Cantiere semantic checkpoint.
  ///
  /// This is deliberately separate from [run] so historical call sites keep
  /// their exact behavior. The resume context is provider-neutral and the
  /// execution identity is forwarded to the runtime without inventing any ID.
  Future<WorkshopChangeProposal> runWithResumeContext({
    required WorkspaceSession session,
    required WorkshopResumeContext resumeContext,
    WorkshopPreflightInferenceResult? preflight,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    _validateSession(session, preflight: preflight);

    if (resumeContext.taskId.trim().isEmpty ||
        resumeContext.executionId.trim().isEmpty ||
        resumeContext.attemptId.trim().isEmpty) {
      throw StateError(
        'Workshop resume context must contain task, execution and attempt IDs.',
      );
    }

    var result = await _inference.completeWithIdentity(
      stage: WorkshopStage.implementation,
      prompt: _buildPrompt(
        session,
        preflight: preflight,
        resumeContext: resumeContext,
      ),
      systemPrompt: _systemPrompt,
      sessionId: resumeContext.sessionId,
      isOffline: isOffline,
      maxTokens: _primaryMaxTokens,
      requestId: session.context.request.id,
      projectId: resumeContext.projectId,
      taskId: resumeContext.taskId,
      executionId: resumeContext.executionId,
      attemptId: resumeContext.attemptId,
      checkpointId: resumeContext.checkpointId,
      cancellationToken: cancellationToken,
    );

    var didRetry = false;
    if (_shouldRetryEngineer(
      result,
      cancellationToken: cancellationToken,
    )) {
      didRetry = true;
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_ENGINEER_RETRY] '
        'request=${session.context.request.id} '
        'execution=${resumeContext.executionId} '
        'attempt=2 reason=runtime terminal=${result.terminalState?.name ?? 'none'}',
      );

      result = await _inference.completeWithIdentity(
        stage: WorkshopStage.implementation,
        prompt: _buildPrompt(
          session,
          preflight: preflight,
          resumeContext: resumeContext,
          compact: true,
        ),
        systemPrompt: _retrySystemPrompt,
        sessionId: '${resumeContext.sessionId}:engineer-retry-1',
        isOffline: isOffline,
        maxTokens: _retryMaxTokens,
        requestId: session.context.request.id,
        projectId: resumeContext.projectId,
        taskId: resumeContext.taskId,
        executionId: resumeContext.executionId,
        attemptId: resumeContext.attemptId,
        checkpointId: resumeContext.checkpointId,
        cancellationToken: cancellationToken,
      );
    }

    try {
      return _stageResult(session: session, result: result);
    } on FormatException catch (error) {
      if (didRetry ||
          cancellationToken?.isCancelled == true ||
          !_isJsonSyntaxFormatException(error)) {
        rethrow;
      }

      RuntimeEventLog.instance.emit(
        '[WORKSHOP_ENGINEER_RETRY] '
        'request=${session.context.request.id} '
        'execution=${resumeContext.executionId} '
        'attempt=2 reason=malformed_output '
        'terminal=${result.terminalState?.name ?? 'none'} '
        'chars=${result.text.length}',
      );

      final recovered = await _inference.completeWithIdentity(
        stage: WorkshopStage.implementation,
        prompt: _buildPrompt(
          session,
          preflight: preflight,
          resumeContext: resumeContext,
          compact: true,
        ),
        systemPrompt: _malformedOutputRetrySystemPrompt,
        sessionId: '${resumeContext.sessionId}:engineer-retry-malformed-1',
        isOffline: isOffline,
        maxTokens: _malformedOutputRetryMaxTokens,
        requestId: session.context.request.id,
        projectId: resumeContext.projectId,
        taskId: resumeContext.taskId,
        executionId: resumeContext.executionId,
        attemptId: resumeContext.attemptId,
        checkpointId: resumeContext.checkpointId,
        cancellationToken: cancellationToken,
      );

      return _stageResult(session: session, result: recovered);
    }
  }

  void _validateSession(
    WorkspaceSession session, {
    WorkshopPreflightInferenceResult? preflight,
  }) {
    if (!session.workspace.isInitialized) {
      throw StateError(
        'Workshop Engineer requires an initialized workspace session.',
      );
    }

    if (session.status != WorkspaceSessionStatus.ready &&
        session.status != WorkspaceSessionStatus.working) {
      throw StateError(
        'Workshop Engineer can only run while the workspace session is ready '
        'or working. Current status: ${session.status.name}.',
      );
    }

    if (preflight != null && !preflight.readyForImplementation) {
      throw StateError(
        'Workshop Engineer cannot run from an incomplete Orchestrator/Architect '
        'preflight.',
      );
    }
  }

  WorkshopChangeProposal _stageResult({
    required WorkspaceSession session,
    required WorkshopInferenceResult result,
  }) {
    if (!result.isSuccessful) {
      final detail = result.errorMessage?.trim();
      throw StateError(
        detail == null || detail.isEmpty
            ? 'Workshop Engineer inference did not complete successfully.'
            : 'Workshop Engineer inference failed: $detail',
      );
    }

    if (!result.hasText) {
      throw StateError('Workshop Engineer returned no change proposal.');
    }

    return _stager.stage(
      session: session,
      responseText: result.text,
    );
  }

  String _buildPrompt(
    WorkspaceSession session, {
    WorkshopPreflightInferenceResult? preflight,
    WorkshopResumeContext? resumeContext,
    bool compact = false,
  }) {
    final request = session.context.request;
    final snapshot = session.workspace.snapshot;

    final architectPlan = _boundedText(
      preflight?.architecture?.text ?? '',
      compact ? _retryArchitectChars : _primaryArchitectChars,
    );
    final certifiedLibraryEvidence = preflight?.certifiedLibraryEvidence;
    final context = _boundedJoined(
      request.context,
      compact ? _retryContextChars : _primaryContextChars,
    );
    final constraints = _boundedJoined(
      request.constraints,
      compact ? _retryConstraintChars : _primaryConstraintChars,
    );
    final workspaceFiles = _selectWorkspaceFiles(
      snapshot: snapshot,
      targetFiles: request.targetFiles,
      maxChars:
          compact ? _retryWorkspaceChars : _primaryWorkspaceChars,
    );

    final manifest = snapshot.keys.toList()..sort();
    final payload = compact
        ? <String, Object?>{
            'request': <String, Object?>{
              'title': _boundedText(request.title, 120),
              'instruction': _boundedText(request.instruction, 320),
              'targetFiles': request.targetFiles,
              if (constraints.isNotEmpty) 'constraints': constraints,
            },
            if (architectPlan.isNotEmpty) 'architectPlan': architectPlan,
            if (certifiedLibraryEvidence != null)
              'certifiedLibraryEvidence': certifiedLibraryEvidence.toJson(),
            if (resumeContext != null)
              'resume': _compactResumeMetadata(resumeContext),
            'workspaceFiles': workspaceFiles,
          }
        : <String, Object?>{
            'request': <String, Object?>{
              'id': request.id,
              'title': _boundedText(request.title, 160),
              'instruction': _boundedText(request.instruction, 560),
              'operation': request.operation.name,
              'targetFiles': request.targetFiles,
              if (constraints.isNotEmpty) 'constraints': constraints,
              if (context.isNotEmpty) 'context': context,
            },
            if (architectPlan.isNotEmpty) 'architectPlan': architectPlan,
            if (certifiedLibraryEvidence != null)
              'certifiedLibraryEvidence': certifiedLibraryEvidence.toJson(),
            if (resumeContext != null) 'resume': resumeContext.toMetadata(),
            'workspaceManifest': manifest.take(28).toList(),
            'workspaceFiles': workspaceFiles,
          };

    final encoded = jsonEncode(payload);
    final prompt = compact
        ? '''
Implement the task from this compact Cantiere input:
$encoded

When certified Module Library evidence is present, preserve every exact pin, use the
already staged certified files from workspaceFiles, and satisfy every explicit
integration requirement. Evidence proves provenance only; it is never approval.

Return ONLY JSON:
{"explanation":"required","changes":[{"path":"relative/path","type":"addition","content":"full content"}],"validationNotes":[],"warnings":[]}

For every change, type MUST be exactly one string: "addition", "modification",
or "deletion". Never copy a list or combine values with "|" or "/".
Every path must be workspace-relative like "lib/main.dart": never prefix it
with "./", never use "../", and never use an absolute path.
Use only workspaceFiles as existing file content. Follow architectPlan. No
markdown, review, approval or apply. For deletion omit content. Every content
value must be a valid JSON string with line breaks, double quotes and
backslashes escaped according to JSON.
'''.trim()
        : '''
Implement exactly one Cantiere task from the bounded input below.
The Architect plan is the authoritative implementation guidance.
When certified Module Library evidence is present, preserve every exact pin, use the
already staged certified files from workspaceFiles, and satisfy every explicit
integration requirement without package substitution. The evidence proves
provenance only and never grants approval or apply authority.
Only current file contents included in workspaceFiles may be modified.
Files listed only in workspaceManifest are informational; do not rewrite them.
New files may be added only when required by the task or Architect plan.

INPUT:
$encoded

Return ONLY JSON:
{"summary":"short","explanation":"required","changes":[{"path":"relative/path","type":"addition","content":"full content for addition or modification"}],"validationNotes":[],"warnings":[]}

For every change, type MUST be exactly one string: "addition", "modification",
or "deletion". Never copy a list or combine values with "|" or "/".
Every path must be workspace-relative like "lib/main.dart": never prefix it
with "./", never use "../", and never use an absolute path.
Do not use markdown. For deletion omit content. Every addition/modification must
contain the complete resulting file content. Every content value must be a valid
JSON string with line breaks, double quotes and backslashes escaped according to
JSON. Do not review, approve or apply.
'''.trim();

    RuntimeEventLog.instance.emit(
      '[WORKSHOP_ENGINEER_PROMPT] '
      'request=${request.id} compact=$compact chars=${prompt.length} '
      'workspace_files=${workspaceFiles.length} '
      'architect_chars=${architectPlan.length} '
      'certified_evidence=${certifiedLibraryEvidence != null}',
    );

    return prompt;
  }

  Map<String, String> _selectWorkspaceFiles({
    required Map<String, String> snapshot,
    required List<String> targetFiles,
    required int maxChars,
  }) {
    final ordered = <String>[];
    final seen = <String>{};

    void addPath(String raw) {
      final path = raw.trim();
      if (path.isEmpty || !snapshot.containsKey(path) || !seen.add(path)) {
        return;
      }
      ordered.add(path);
    }

    for (final path in targetFiles) {
      addPath(path);
    }

    for (final path in const <String>[
      'pubspec.yaml',
      'lib/main.dart',
      'android/app/src/main/AndroidManifest.xml',
      'android/app/build.gradle.kts',
      'android/app/build.gradle',
    ]) {
      addPath(path);
    }

    final remainingPaths = snapshot.keys
        .where((path) => !seen.contains(path))
        .toList()
      ..sort((left, right) {
        final leftLib = left.startsWith('lib/') ? 0 : 1;
        final rightLib = right.startsWith('lib/') ? 0 : 1;
        final byPriority = leftLib.compareTo(rightLib);
        return byPriority != 0 ? byPriority : left.compareTo(right);
      });
    for (final path in remainingPaths) {
      addPath(path);
    }

    var used = 0;
    final selected = <String, String>{};
    for (final path in ordered) {
      final content = snapshot[path] ?? '';
      final cost = path.length + content.length;
      if (selected.isNotEmpty && used + cost > maxChars) {
        continue;
      }
      if (content.length > maxChars && targetFiles.contains(path)) {
        throw StateError(
          'Workshop Engineer target file "$path" exceeds the local prompt '
          'budget; split the task before implementation.',
        );
      }
      if (used + cost > maxChars) {
        continue;
      }
      selected[path] = content;
      used += cost;
    }
    return selected;
  }

  static Map<String, Object?> _compactResumeMetadata(
    WorkshopResumeContext resume,
  ) {
    return <String, Object?>{
      'objective': _boundedText(resume.objective, 180),
      'phase': resume.phase,
      if (resume.completedSteps.isNotEmpty)
        'completedSteps': resume.completedSteps.take(4).toList(),
      if (resume.remainingWork.isNotEmpty)
        'remainingWork': resume.remainingWork.take(4).toList(),
      if (resume.nextStep != null && resume.nextStep!.trim().isNotEmpty)
        'nextStep': _boundedText(resume.nextStep!, 180),
      if (resume.verified.isNotEmpty)
        'verified': resume.verified.take(4).toList(),
    };
  }

  static bool _isJsonSyntaxFormatException(FormatException error) {
    return error.source != null || error.offset != null;
  }

  static bool _shouldRetryEngineer(
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

    if (result.terminalState == InferenceTerminalState.timeout) {
      return true;
    }

    final error = (result.errorMessage ?? '').toLowerCase();
    return error.contains('stalled') ||
        error.contains('timeout') ||
        error.contains('timed out');
  }

  static String _boundedText(String raw, int maxChars) {
    final value = raw.trim();
    if (value.length <= maxChars) {
      return value;
    }
    return '${value.substring(0, maxChars)}…';
  }

  static String _boundedJoined(Iterable<String> values, int maxChars) {
    final normalized = values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .join(' | ');
    return _boundedText(normalized, maxChars);
  }

  static const String _systemPrompt =
      'You are the Engineer brain of the Cantiere. Implement only the bounded '
      'task input and exact workspace file contents supplied. The Architect '
      'plan is authoritative. When certified Module Library evidence is '
      'present, preserve exact pins and explicit integration requirements; '
      'treat that evidence as verified provenance only, never as approval. '
      'Do not use Assistant memory or hidden project state. Return only the '
      'requested structured JSON proposal and never mutate the real repository '
      'directly.';

  static const String _retrySystemPrompt =
      'You are the Cantiere Engineer retrying after a local first-token stall. '
      'Use only the compact bounded input. Make the smallest valid change that '
      'satisfies the Architect plan. Preserve exact certified Library pins and '
      'explicit integration requirements when evidence is supplied; evidence '
      'is provenance, never approval. Return only the requested JSON object. '
      'Do not review, approve, apply, or use Assistant state.';

  static const String _malformedOutputRetrySystemPrompt =
      'You are the Cantiere Engineer retrying because the previous structured '
      'response was incomplete or invalid JSON. Use only the compact bounded '
      'input and satisfy the core required behavior from the Architect plan. '
      'Produce the smallest complete compilable change, preferably one concise '
      'file when possible. Finish valid JSON before optional features or UI '
      'polish. Every change type must be exactly addition, modification, or '
      'deletion; never combine enum values. Escape all file content as valid '
      'JSON strings. Do not review, approve, apply, or use Assistant state.';
}
