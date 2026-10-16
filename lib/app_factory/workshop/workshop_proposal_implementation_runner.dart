import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal_decoder.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_workspace_stager.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_plan_projection.dart';
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
  static const int _primaryWorkspaceChars = 1800;
  static const int _retryWorkspaceChars = 900;
  static const int _buildRepairTargetChars = 6400;
  static const int _primaryContextChars = 360;
  static const int _retryContextChars = 220;
  static const int _primaryConstraintChars = 360;
  static const int _retryConstraintChars = 220;
  static const int _primaryRevisionFeedbackChars = 700;
  static const int _retryRevisionFeedbackChars = 420;

  Future<WorkshopChangeProposal> run({
    required WorkspaceSession session,
    WorkshopPreflightInferenceResult? preflight,
    String? revisionFeedback,
    int revisionAttempt = 0,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    _validateSession(session, preflight: preflight);

    final revisionSuffix =
        revisionAttempt > 0 ? ':revision-$revisionAttempt' : '';
    final sessionId =
        'workshop:implementation:${session.context.request.id}$revisionSuffix';

    final compactPrimary = revisionAttempt > 0;
    var result = await _inference.complete(
      stage: WorkshopStage.implementation,
      prompt: _buildPrompt(
        session,
        preflight: preflight,
        revisionFeedback: revisionFeedback,
        compact: compactPrimary,
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
        'attempt=2 reason=${_retryReason(result)} '
        'terminal=${result.terminalState?.name ?? 'none'}',
      );

      result = await _inference.complete(
        stage: WorkshopStage.implementation,
        prompt: _buildPrompt(
          session,
          preflight: preflight,
          revisionFeedback: revisionFeedback,
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
      if (cancellationToken?.isCancelled == true ||
          !_isRetryableProposalFormatException(error)) {
        rethrow;
      }

      RuntimeEventLog.instance.emit(
        '[WORKSHOP_ENGINEER_RETRY] '
        'request=${session.context.request.id} '
        'attempt=${didRetry ? 3 : 2} reason=malformed_output '
        'terminal=${result.terminalState?.name ?? 'none'} '
        'chars=${result.text.length}',
      );

      final structuralFeedback = <String>[
        'Previous Engineer proposal was rejected before review: '
            '${error.message}',
        if (revisionFeedback != null && revisionFeedback.trim().isNotEmpty)
          revisionFeedback.trim(),
      ].join(' | ');

      final recovered = await _inference.complete(
        stage: WorkshopStage.implementation,
        prompt: _buildPrompt(
          session,
          preflight: preflight,
          revisionFeedback: structuralFeedback,
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
    String? revisionFeedback,
    int revisionAttempt = 0,
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

    final revisionSuffix =
        revisionAttempt > 0 ? ':revision-$revisionAttempt' : '';
    final compactPrimary = revisionAttempt > 0;
    var result = await _inference.completeWithIdentity(
      stage: WorkshopStage.implementation,
      prompt: _buildPrompt(
        session,
        preflight: preflight,
        resumeContext: resumeContext,
        revisionFeedback: revisionFeedback,
        compact: compactPrimary,
      ),
      systemPrompt: _systemPrompt,
      sessionId: '${resumeContext.sessionId}$revisionSuffix',
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
        'attempt=2 reason=${_retryReason(result)} '
        'terminal=${result.terminalState?.name ?? 'none'}',
      );

      result = await _inference.completeWithIdentity(
        stage: WorkshopStage.implementation,
        prompt: _buildPrompt(
          session,
          preflight: preflight,
          resumeContext: resumeContext,
          revisionFeedback: revisionFeedback,
          compact: true,
        ),
        systemPrompt: _retrySystemPrompt,
        sessionId: '${resumeContext.sessionId}$revisionSuffix:engineer-retry-1',
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
      if (cancellationToken?.isCancelled == true ||
          !_isRetryableProposalFormatException(error)) {
        rethrow;
      }

      RuntimeEventLog.instance.emit(
        '[WORKSHOP_ENGINEER_RETRY] '
        'request=${session.context.request.id} '
        'execution=${resumeContext.executionId} '
        'attempt=${didRetry ? 3 : 2} reason=malformed_output '
        'terminal=${result.terminalState?.name ?? 'none'} '
        'chars=${result.text.length}',
      );

      final structuralFeedback = <String>[
        'Previous Engineer proposal was rejected before review: '
            '${error.message}',
        if (revisionFeedback != null && revisionFeedback.trim().isNotEmpty)
          revisionFeedback.trim(),
      ].join(' | ');

      final recovered = await _inference.completeWithIdentity(
        stage: WorkshopStage.implementation,
        prompt: _buildPrompt(
          session,
          preflight: preflight,
          resumeContext: resumeContext,
          revisionFeedback: structuralFeedback,
          compact: true,
        ),
        systemPrompt: _malformedOutputRetrySystemPrompt,
        sessionId:
            '${resumeContext.sessionId}$revisionSuffix:engineer-retry-malformed-1',
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

    // Fail before staging: Android res/drawable is not a Flutter asset.
    // A bounded malformed-proposal retry can then repair this concrete error.
    _rejectInvalidFlutterResourceLookup(session, result.text);
    return _stager.stage(
      session: session,
      responseText: result.text,
    );
  }

  static void _rejectInvalidFlutterResourceLookup(
    WorkspaceSession session,
    String responseText,
  ) {
    // Decode through the same normalizer as the stager: local proposals may
    // carry JSON fences, leading prose, file aliases or repaired strings.
    // Check exactly the file contents that would otherwise be staged.
    final proposal = WorkshopChangeProposalDecoder.decode(
      requestId: session.context.request.id,
      responseText: responseText,
      existingPaths: session.workspace.paths.toSet(),
    );
    var pubspec = session.workspace.read('pubspec.yaml');
    for (final change in proposal.changes) {
      if (change.path == 'pubspec.yaml') {
        pubspec = change.isDeletion ? null : change.afterContent;
      }
    }
    for (final change in proposal.changes) {
      if (change.isDeletion ||
          !change.path.toLowerCase().endsWith('.dart')) {
        continue;
      }
      final content = change.afterContent;
      if (content == null) continue;
      if (_usesNativeDrawableAsFlutterAsset(content, pubspec: pubspec)) {
        throw FormatException(
          'Flutter rootBundle cannot load Android res/drawable files as '
          'Flutter assets. Use Dart widgets or a declared Flutter asset; '
          'preserve only the behavior required by the current task.',
          change.path,
        );
      }
    }
  }

  // Lex source, rather than regexp matching the raw file: literal text in a
  // comment, documentation or string is not an invocation. This is a bounded
  // source-shape guard, not a substitute for analyzer, Reviewer or Validation.
  static bool _usesNativeDrawableAsFlutterAsset(
    String source, {
    required String? pubspec,
  }) {
    final tokens = _dartSourceTokens(source);
    const loadMethods = <String>{
      'load',
      'loadString',
      'loadBuffer',
      'loadStructuredData',
      'loadStructuredBinaryData',
    };
    for (var i = 0; i + 4 < tokens.length; i++) {
      if (tokens[i].isString || tokens[i].value != 'rootBundle') continue;
      // Account for ordinary method calls, null-aware access and the Dart
      // cascade syntax: rootBundle..loadString('...').
      var member = i + 1;
      if (tokens[member].value == '?') member++;
      if (member >= tokens.length || tokens[member].value != '.') continue;
      member++;
      if (member < tokens.length && tokens[member].value == '.') member++;
      if (member + 2 >= tokens.length ||
          !loadMethods.contains(tokens[member].value) ||
          tokens[member + 1].value != '(' ||
          !tokens[member + 2].isString) {
        continue;
      }
      final path = tokens[member + 2].value;
      if ((path.startsWith('drawable/') ||
              path.startsWith('res/drawable/') ||
              path.startsWith('android/app/src/main/res/')) &&
          !_isDeclaredFlutterAsset(path, pubspec)) {
        return true;
      }
    }
    return false;
  }

  // Only actual flutter.assets entries authorize keys under drawable/.
  // Supports individual files and Flutter asset-directory prefixes, but
  // never treats Android's res/drawable folder as a Flutter declaration.
  static bool _isDeclaredFlutterAsset(String path, String? pubspec) {
    if (pubspec == null || pubspec.isEmpty) return false;
    var inFlutter = false;
    var inAssets = false;
    int? flutterChildIndent;
    int? assetEntryIndent;
    for (final line in pubspec.split('\n')) {
      final trimmed = _withoutYamlInlineComment(line.trim());
      if (trimmed.isEmpty) continue;
      final indent = line.length - line.trimLeft().length;
      if (indent == 0) {
        inFlutter = trimmed == 'flutter:';
        inAssets = false;
        flutterChildIndent = null;
        assetEntryIndent = null;
        continue;
      }
      if (!inFlutter) continue;
      // YAML block indentation is relative to its parent, not a fixed
      // number of spaces. Only direct children of flutter: are eligible
      // for an assets: list, never nested unrelated keys.
      flutterChildIndent ??= indent;
      // YAML also permits an indentationless sequence: the '-' may align
      // with the assets: key rather than being indented further.
      final isListEntry = trimmed.startsWith('- ');
      if (indent == flutterChildIndent && !(inAssets && isListEntry)) {
        inAssets = trimmed == 'assets:';
        assetEntryIndent = null;
        continue;
      }
      if (!inAssets || indent < flutterChildIndent) continue;
      if (!isListEntry) {
        // A nested mapping or scalar under assets: is not a direct member
        // of the Flutter asset list. Never treat later nested '-' entries as
        // authorized Flutter asset keys.
        inAssets = false;
        assetEntryIndent = null;
        continue;
      }
      assetEntryIndent ??= indent;
      if (indent != assetEntryIndent) continue;
      var entry = trimmed.substring(2).trim();
      if (entry.length >= 2 &&
          ((entry.startsWith("'") && entry.endsWith("'")) ||
              (entry.startsWith('"') && entry.endsWith('"')))) {
        entry = entry.substring(1, entry.length - 1);
      }
      // Declaring a directory packages its immediate files, not arbitrary
      // descendants. Subdirectories must have their own assets: entries.
      final child = entry.endsWith('/') && path.startsWith(entry)
          ? path.substring(entry.length)
          : '';
      if (entry == path || (child.isNotEmpty && !child.contains('/'))) {
        return true;
      }
    }
    return false;
  }

  static String _withoutYamlInlineComment(String text) {
    String? quote;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == r'\' && quote == '"' && i + 1 < text.length) {
        i++;
        continue;
      }
      if (quote == "'" && ch == "'" && i + 1 < text.length &&
          text[i + 1] == "'") {
        i++;
        continue;
      }
      if ((ch == "'" || ch == '"')) {
        if (quote == null) {
          quote = ch;
        } else if (quote == ch) {
          quote = null;
        }
        continue;
      }
      if (ch == '#' &&
          quote == null &&
          (i == 0 || RegExp(r'\s').hasMatch(text[i - 1]))) {
        return text.substring(0, i).trimRight();
      }
    }
    return text;
  }

  // Tokenize executable Dart including nested \${...} interpolation, without
  // misclassifying documentation, strings or comments as live invocations.
  // This bounded lexer is not an analyzer; later review/validation remain strict.
  static List<_WorkshopDartSourceToken> _dartSourceTokens(String source) {
    final result = <_WorkshopDartSourceToken>[];
    late int Function(int, {required bool untilClosingBrace}) scan;
    scan = (int start, {required bool untilClosingBrace}) {
      var offset = start;
      var braceDepth = 0;
      while (offset < source.length) {
        final ch = source[offset];
        final next = offset + 1 < source.length ? source[offset + 1] : '';
        if (RegExp(r'\s').hasMatch(ch)) {
          offset++;
          continue;
        }
        if (ch == '/' && next == '/') {
          offset += 2;
          while (offset < source.length &&
              source[offset] != '\n' &&
              source[offset] != '\r') {
            offset++;
          }
          continue;
        }
        if (ch == '/' && next == '*') {
          var depth = 1;
          offset += 2;
          while (offset < source.length && depth > 0) {
            if (source.startsWith('/*', offset)) {
              depth++;
              offset += 2;
            } else if (source.startsWith('*/', offset)) {
              depth--;
              offset += 2;
            } else {
              offset++;
            }
          }
          continue;
        }
        if (ch == '}' && untilClosingBrace) {
          if (braceDepth == 0) return offset + 1;
          braceDepth--;
        } else if (ch == '{' && untilClosingBrace) {
          braceDepth++;
        }
        final raw = (ch == 'r' || ch == 'R') &&
            (next == "'" || next == '"');
        if (raw || ch == "'" || ch == '"') {
          final quoteOffset = raw ? offset + 1 : offset;
          final quote = source[quoteOffset];
          final triple = source.startsWith('$quote$quote$quote', quoteOffset);
          var cursor = quoteOffset + (triple ? 3 : 1);
          var literalStart = cursor;
          while (cursor < source.length) {
            if (!raw && source.codeUnitAt(cursor) == 92) {
              cursor += 2;
              continue;
            }
            if (triple
                ? source.startsWith('$quote$quote$quote', cursor)
                : source[cursor] == quote) {
              break;
            }
            if (!raw && source.startsWith(r'${', cursor)) {
              // Keep the surrounding literal separate from executable code.
              result.add(_WorkshopDartSourceToken(
                source.substring(literalStart, cursor),
                isString: true,
              ));
              cursor = scan(cursor + 2, untilClosingBrace: true);
              literalStart = cursor;
              continue;
            }
            cursor++;
          }
          result.add(_WorkshopDartSourceToken(
            source.substring(literalStart,
                cursor < source.length ? cursor : source.length),
            isString: true,
          ));
          offset = cursor < source.length
              ? cursor + (triple ? 3 : 1)
              : source.length;
          continue;
        }
        if (_isDartSourceIdentifierChar(ch)) {
          final begin = offset;
          while (offset < source.length &&
              _isDartSourceIdentifierChar(source[offset])) {
            offset++;
          }
          result.add(_WorkshopDartSourceToken(
              source.substring(begin, offset)));
          continue;
        }
        result.add(_WorkshopDartSourceToken(ch));
        offset++;
      }
      return offset;
    };
    scan(0, untilClosingBrace: false);
    return result;
  }

  static bool _isDartSourceIdentifierChar(String c) {
    if (c.isEmpty) return false;
    final unit = c.codeUnitAt(0);
    return (unit >= 65 && unit <= 90) ||
        (unit >= 97 && unit <= 122) ||
        (unit >= 48 && unit <= 57) ||
        c == '_' ||
        c == r'$';
  }

  String _buildPrompt(
    WorkspaceSession session, {
    WorkshopPreflightInferenceResult? preflight,
    WorkshopResumeContext? resumeContext,
    String? revisionFeedback,
    bool compact = false,
  }) {
    final request = session.context.request;
    final snapshot = session.workspace.snapshot;
    final taskText = '${request.title} ${request.instruction}'.toLowerCase();
    final mentionsStar = RegExp(r'\b(stella|stelle|star|stars)\b').hasMatch(taskText);
    final requestsTouch =
        RegExp(r'\b(tocc\w*|tap\w*|tapp\w*|clic\w*|click\w*|prem\w*)\b')
            .hasMatch(taskText);
    final requestsColorChange =
        RegExp(r'\b(cambi\w*|modific\w*|altern\w*|chang\w*|switch\w*|cycl\w*|varia\w*)\b')
                .hasMatch(taskText) &&
            RegExp(r'\b(colou?r\w*|tint\w*)\b').hasMatch(taskText);
    final starAcceptance = mentionsStar && requestsTouch && requestsColorChange
        ? 'ACCEPTANCE: follow only the explicitly requested star interaction. '
            'If the task requires tapping to change the STAR color, update '
            'that star via Flutter state/setState, not unrelated background. '
            'Preserve the specified layout, backdrop and initial colors; '
            'do not add defaults or extra behavior.'
        : '';
    final architectPlan = WorkshopTaskPlanProjection.project(
      preflight?.architecture?.text,
    );
    final context = _boundedJoined(
      request.context,
      compact ? _retryContextChars : _primaryContextChars,
    );
    final constraints = _boundedJoined(
      request.constraints,
      compact ? _retryConstraintChars : _primaryConstraintChars,
    );
    final feedback = _boundedText(
      revisionFeedback ?? '',
      compact ? _retryRevisionFeedbackChars : _primaryRevisionFeedbackChars,
    );
    final boundedBuildRepair = _isBoundedBuildRepair(request);
    final workspaceSelection = _selectWorkspaceFiles(
      snapshot: snapshot,
      targetFiles: request.targetFiles,
      maxChars: compact ? _retryWorkspaceChars : _primaryWorkspaceChars,
      allowOversizedTargetReplacement:
          request.operation == WorkshopOperation.create,
      oversizedTargetReadLimit:
          boundedBuildRepair ? _buildRepairTargetChars : null,
    );
    final workspaceFiles = workspaceSelection.files;
    final replaceableTargets = workspaceSelection.replaceableTargets;

    final manifest = snapshot.keys.toList()..sort();
    final payload = compact
        ? <String, Object?>{
            'request': <String, Object?>{
              'title': _boundedText(request.title, 120),
              'instruction': _boundedText(request.instruction, 320),
              'operation': request.operation.name,
              'targetFiles': request.targetFiles,
              'targetFilesPolicy': request.targetFiles.isEmpty
                  ? 'open_for_required_new_files'
                  : 'hard_allowlist',
              if (constraints.isNotEmpty) 'constraints': constraints,
            },
            if (architectPlan.isNotEmpty) 'architectPlan': architectPlan,
            if (resumeContext != null)
              'resume': _compactResumeMetadata(resumeContext),
            if (feedback.isNotEmpty) 'gateFeedback': feedback,
            if (replaceableTargets.isNotEmpty)
              'replaceableTargets': replaceableTargets,
            'workspaceFiles': workspaceFiles,
          }
        : <String, Object?>{
            'request': <String, Object?>{
              'id': request.id,
              'title': _boundedText(request.title, 160),
              'instruction': _boundedText(request.instruction, 560),
              'operation': request.operation.name,
              'targetFiles': request.targetFiles,
              'targetFilesPolicy': request.targetFiles.isEmpty
                  ? 'open_for_required_new_files'
                  : 'hard_allowlist',
              if (constraints.isNotEmpty) 'constraints': constraints,
              if (context.isNotEmpty) 'context': context,
            },
            if (architectPlan.isNotEmpty) 'architectPlan': architectPlan,
            if (resumeContext != null) 'resume': resumeContext.toMetadata(),
            if (feedback.isNotEmpty) 'gateFeedback': feedback,
            if (replaceableTargets.isNotEmpty)
              'replaceableTargets': replaceableTargets,
            'workspaceManifest': manifest.take(28).toList(),
            'workspaceFiles': workspaceFiles,
          };

    final encoded = jsonEncode(payload);
    final prompt = compact
        ? '''
Implement the task from this compact Cantiere input:
$encoded

Return ONLY JSON:
{"explanation":"required","changes":[{"path":"relative/path","type":"addition","content":"full content"}],"validationNotes":[],"warnings":[]}

changes MUST contain at least one real file change. Never return an empty changes
array. type must be exactly "addition", "modification" or "deletion".
Use workspace-relative paths: no "./", "../" or absolute paths.
request.targetFiles is a HARD ALLOWLIST when non-empty; an empty list permits
only files required by the explicit task. Do not invent supporting files outside it.
Only workspaceFiles supplies existing content. replaceableTargets are oversized
starter files omitted for operation "create": replace them only with complete
resulting content; never infer or partially preserve omitted content.
For "create", materialize the smallest runnable task increment even over a scaffold.
The explicit task instruction and constraints are authoritative; architectPlan
is guidance and must not override them. $starAcceptance
gateFeedback is authoritative feedback
on the rejected proposal, never approval. Correct the reported mismatch.
UI LITERAL FIDELITY: preserve labels, titles, units and symbols verbatim; never
"improve" "+" into "+1" or rename "Azzera" without an explicit request.
For addition/modification supply complete content as a valid JSON string with
quotes, newlines and backslashes escaped. For deletion omit content.
A Flutter app targeting Android uses Dart widgets for UI/touch (e.g.
GestureDetector + setState). Never import Kotlin/Java classes into Dart.
Native Kotlin/XML requires a real declared platform-channel integration.
Opaque black in Flutter is 0xFF000000, not 0xFF0000.
For a UI-only CREATE, prefer a complete self-contained Flutter lib/main.dart
when it is within targetFiles: provide main() + runApp(), define every custom
widget or import only files that actually exist in the workspace or allowed
changes. Container.color expects a Color (e.g. Colors.black), not a bare int.
Import dart:math when using Random; do not emit literal backslash-n escapes
outside strings. No unresolved native XML classes or platform-view references.
Prefer SDK-only Flutter/Dart. Any undeclared third-party import requires its
matching pubspec.yaml change within the allowlist. No unused imports; satisfy
flutter analyze lints. Rebuild changed StatefulWidget state with setState or an
already-declared equivalent. Never simulate real sensor/health measurements.
Return only JSON; no Markdown, review, approval, apply or Assistant state.
'''
            .trim()
        : '''
Implement exactly one Cantiere task from the bounded input below.
The explicit task instruction and constraints are authoritative.
UI LITERAL FIDELITY: preserve every explicit user-visible literal from the task
or constraints verbatim unless the task explicitly asks to rename it. This
includes button labels, titles, field labels, units and short symbols. Do not
"improve" "+" into "+1", rename "Azzera", or otherwise substitute a visible
string just because it seems equivalent. The Architect
plan is model-authored implementation guidance and must not override or
contradict the explicit task. If request.targetFiles is empty for an initial
create task, paths were not preselected; it does not mean no file may be
changed. Only current file contents included in workspaceFiles may be modified, except
paths listed in replaceableTargets. replaceableTargets are existing oversized
starter files intentionally omitted from the prompt for this create task; they
may be replaced only with complete resulting content, never partially edited or
assumed from unseen prior text. Files listed only in workspaceManifest are
informational; do not rewrite them. When request.targetFiles is non-empty it
is a HARD ALLOWLIST: every changes[].path MUST be exactly one of those paths.
Do not invent, split into, or add supporting files outside that list, even if
the Architect plan suggests one. New files may be added only when
request.targetFiles is empty and the explicit task requires them. When
gateFeedback is present, it is authoritative Reviewer/Validation feedback about
the previous rejected staged proposal. Correct that concrete issue while keeping
the current task bounded. If the feedback says the Architect plan or target
files do not match the explicit task, follow the explicit instruction and
constraints rather than repeating the mismatched plan. Do not treat the
previous proposal as approved.

$starAcceptance

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
JSON. Flutter Android UI belongs in Dart. Implement taps with Flutter widgets and
state updates, not unimplemented Kotlin/XML classes. Never import JVM class
names directly into Dart. Opaque black uses 0xFF000000 / Colors.black.
For UI-only CREATE tasks, prefer one complete lib/main.dart when that path is
authorized. Include main() + runApp(), and define every referenced custom Dart
widget in the changed files or import only existing/authorized source files.
Container.color requires a Color, not a bare int (e.g. Colors.black or
const Color(0xFF000000)). Random requires import 'dart:math'. Avoid literal
backslash-n tokens outside source strings and unresolved native XML classes.
Prefer Flutter/Dart SDK-only code for the smallest MVP. If a third-party
package is truly required and is not already declared, include the matching
pubspec.yaml addition/modification in the same proposal. Never emit an
undeclared package import or an unused import. Generated Dart must be clean
under default flutter analyze lints. Public widget APIs must follow those lints,
and UI-visible StatefulWidget mutations must trigger a rebuild with setState or
an already-declared equivalent mechanism. Do not invent or simulate sensor or
health measurements as real tracking unless verified integration was explicitly
requested. Do not review, approve or apply.
'''
            .trim();

    RuntimeEventLog.instance.emit(
      '[WORKSHOP_ENGINEER_PROMPT] '
      'request=${request.id} compact=$compact chars=${prompt.length} '
      'workspace_files=${workspaceFiles.length} '
      'replaceable_targets=${replaceableTargets.length} '
      'architect_chars=${architectPlan.length}',
    );

    return prompt;
  }

  _WorkshopWorkspaceSelection _selectWorkspaceFiles({
    required Map<String, String> snapshot,
    required List<String> targetFiles,
    required int maxChars,
    required bool allowOversizedTargetReplacement,
    int? oversizedTargetReadLimit,
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

    final remainingPaths =
        snapshot.keys.where((path) => !seen.contains(path)).toList()
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
    final replaceableTargets = <String>[];
    for (final path in ordered) {
      final content = snapshot[path] ?? '';
      final cost = path.length + content.length;
      if (selected.isNotEmpty && used + cost > maxChars) {
        continue;
      }
      if (content.length > maxChars && targetFiles.contains(path)) {
        if (allowOversizedTargetReplacement) {
          replaceableTargets.add(path);
          continue;
        }
        final readLimit = oversizedTargetReadLimit;
        if (readLimit != null && content.length <= readLimit) {
          selected[path] = content;
          used += cost;
          continue;
        }
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
    return _WorkshopWorkspaceSelection(
      files: Map<String, String>.unmodifiable(selected),
      replaceableTargets: List<String>.unmodifiable(replaceableTargets),
    );
  }

  static bool _isBoundedBuildRepair(WorkshopRequest request) {
    if (request.operation != WorkshopOperation.fix ||
        request.targetFiles.isEmpty) {
      return false;
    }

    return request.title == 'Correzione build mirata' ||
        request.instruction
            .toUpperCase()
            .startsWith('BUILD REPAIR ATTEMPT:');
  }

  static Map<String, Object?> _compactResumeMetadata(
    WorkshopResumeContext resume,
  ) {
    return <String, Object?>{
      'objective': _boundedText(resume.objective, 180),
      'phase': _boundedText(resume.phase, 80),
      if (resume.completedSteps.isNotEmpty)
        'completedSteps': resume.completedSteps
            .take(4)
            .map((value) => _boundedText(value, 80))
            .toList(),
      if (resume.remainingWork.isNotEmpty)
        'remainingWork': resume.remainingWork
            .take(4)
            .map((value) => _boundedText(value, 80))
            .toList(),
      if (resume.nextStep != null && resume.nextStep!.trim().isNotEmpty)
        'nextStep': _boundedText(resume.nextStep!, 180),
      if (resume.verified.isNotEmpty)
        'verified': resume.verified
            .take(4)
            .map((value) => _boundedText(value, 80))
            .toList(),
    };
  }

  static bool _isRetryableProposalFormatException(FormatException error) {
    if (error.source != null || error.offset != null) {
      return true;
    }

    final message = error.message.toString();
    return message == 'Workshop proposal field "explanation" is required.' ||
        message == 'Workshop proposal field "explanation" must be text.' ||
        message == 'Workshop proposal field "path" is required.' ||
        message == 'Workshop proposal field "path" must be text.' ||
        message == 'Workshop proposal must contain at least one file change.' ||
        message == 'Workshop proposal produced no staged workspace changes.' ||
        message.startsWith('Workshop proposal path "') ||
        message ==
            'Workshop create proposal must materialize required target '
                '"lib/main.dart".';
  }

  static bool _isCriticalMemoryError(
    WorkshopInferenceResult result,
  ) {
    final error = (result.errorMessage ?? '').toLowerCase();
    return error.contains('stage=critical_memory') ||
        error.contains('reason=critical_memory') ||
        error.contains('pressione sulla memoria');
  }

  static bool _shouldRetryEngineer(
    WorkshopInferenceResult result, {
    CancellationToken? cancellationToken,
  }) {
    if (result.isSuccessful && result.hasText) {
      return false;
    }

    // A caller cancellation is authoritative. The Workshop gateway now
    // forwards it one-way to a per-inference runtime token, so an internal
    // critical-memory cancellation cannot poison this outer task token.
    if (cancellationToken?.isCancelled == true ||
        result.terminalState == InferenceTerminalState.cancelled ||
        result.terminalState == InferenceTerminalState.modelUnavailable) {
      return false;
    }

    if (_isCriticalMemoryError(result) ||
        _isPromptBudgetError(result) ||
        _isRetryableIncompleteCloudOutput(result)) {
      return true;
    }

    if (result.terminalState == InferenceTerminalState.timeout) {
      return true;
    }

    final error = (result.errorMessage ?? '').toLowerCase();
    return error.contains('stalled') ||
        error.contains('timeout') ||
        error.contains('timed out');
  }

  static bool _isPromptBudgetError(WorkshopInferenceResult result) {
    final error = (result.errorMessage ?? '').toLowerCase();
    return error.contains('stage=prompt_budget') ||
        error.contains('prompt exceeds the local context capacity');
  }

  static bool _isRetryableIncompleteCloudOutput(
    WorkshopInferenceResult result,
  ) {
    final error = (result.errorMessage ?? '').toLowerCase();
    if (!error.contains('response was incomplete')) {
      return false;
    }

    return error.contains('(length)') ||
        error.contains('(max_tokens)') ||
        error.contains('(max_output_tokens)') ||
        error.contains('(max_tokens_reached)');
  }

  static String _retryReason(WorkshopInferenceResult result) {
    if (_isPromptBudgetError(result)) return 'prompt_budget';
    if (_isCriticalMemoryError(result)) return 'memory_pressure';
    if (_isRetryableIncompleteCloudOutput(result)) return 'incomplete_output';
    return 'runtime';
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
      'task input and exact workspace file contents supplied. The explicit task '
      'instruction, constraints and acceptance scope are authoritative; the '
      'Architect plan is bounded implementation guidance and must not override '
      'them. Do not use Assistant memory or hidden project state. Return only '
      'the requested structured JSON proposal and never mutate the real '
      'repository directly.';

  static const String _retrySystemPrompt =
      'You are the Cantiere Engineer retrying after a runtime, prompt-budget, '
      'or incomplete-output failure. Use only the compact bounded input. Make '
      'the smallest valid change that satisfies the explicit task contract; '
      'use the Architect plan only as bounded implementation guidance. Return '
      'only the requested JSON object. Do not review, approve, apply, or use '
      'Assistant state.';

  static const String _malformedOutputRetrySystemPrompt =
      'You are the Cantiere Engineer retrying because the previous structured '
      'response was incomplete, invalid JSON, omitted a required proposal '
      'field, or produced no material workspace diff. Use only the compact '
      'bounded input and satisfy the core required behavior from the explicit '
      'task contract, using the Architect plan only as bounded implementation '
      'guidance. Return one complete JSON object with a non-empty string field '
      '"explanation" and a non-empty "changes" array. At least one proposed '
      'change must alter the current workspace content; rewriting identical '
      'content is invalid. '
      'Produce the smallest complete compilable change, preferably one concise '
      'file when possible. Never import Android/JVM classes directly into '
      'Dart; keep Flutter UI and touch behavior in Dart widgets. '
      'The compact input targetFiles are a hard allowlist: '
      'never invent a path outside them. If the rejected proposal used an '
      'outside path, fold that behavior into an allowed target file instead '
      'of proposing the outside file again. Finish valid JSON before optional '
      'features or UI polish. Every change type must be exactly addition, '
      'modification, or '
      'deletion; never combine enum values. Escape all file content as valid '
      'JSON strings. Do not review, approve, apply, or use Assistant state.';
}

final class _WorkshopWorkspaceSelection {
  const _WorkshopWorkspaceSelection({
    required this.files,
    required this.replaceableTargets,
  });

  final Map<String, String> files;
  final List<String> replaceableTargets;
}

final class _WorkshopDartSourceToken {
  const _WorkshopDartSourceToken(this.value, {this.isString = false});

  final String value;
  final bool isString;
}
