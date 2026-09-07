import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_workspace_stager.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

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

  Future<WorkshopChangeProposal> run({
    required WorkspaceSession session,
    WorkshopPreflightInferenceResult? preflight,
    bool isOffline = true,
    CancellationToken? cancellationToken,
  }) async {
    _validateSession(session, preflight: preflight);

    final result = await _inference.complete(
      stage: WorkshopStage.implementation,
      prompt: _buildPrompt(session, preflight: preflight),
      systemPrompt: _systemPrompt,
      sessionId: 'workshop:implementation:${session.context.request.id}',
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    return _stageResult(session: session, result: result);
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
    bool isOffline = true,
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

    final result = await _inference.completeWithIdentity(
      stage: WorkshopStage.implementation,
      prompt: _buildPrompt(
        session,
        preflight: preflight,
        resumeContext: resumeContext,
      ),
      systemPrompt: _systemPrompt,
      sessionId: resumeContext.sessionId,
      isOffline: isOffline,
      requestId: session.context.request.id,
      projectId: resumeContext.projectId,
      taskId: resumeContext.taskId,
      executionId: resumeContext.executionId,
      attemptId: resumeContext.attemptId,
      checkpointId: resumeContext.checkpointId,
      cancellationToken: cancellationToken,
    );

    return _stageResult(session: session, result: result);
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
  }) {
    final request = session.context.request;
    final snapshot = session.workspace.snapshot;

    final payload = <String, Object?>{
      'requestId': request.id,
      'title': request.title,
      'instruction': request.instruction,
      'operation': request.operation.name,
      'targetFiles': request.targetFiles,
      'constraints': request.constraints,
      'context': request.context,
      if (preflight != null)
        'preflight': <String, String>{
          'orchestratorAnalysis': preflight.analysis.text.trim(),
          'architectPlan': preflight.architecture!.text.trim(),
        },
      if (resumeContext != null) 'resume': resumeContext.toMetadata(),
      'workspaceFiles': <String, String>{
        for (final path in snapshot.keys.toList()..sort()) path: snapshot[path]!,
      },
    };

    return '''
Implement the Workshop task using only the supplied request, Cantiere preflight
when present, authoritative Cantiere resume state when present, and workspace
snapshot. Treat the Architect plan as bounded implementation guidance. When a
resume state is supplied, continue from its completed steps, decisions,
verification state and next step instead of restarting the task. Preserve all
supplied constraints. Return a structured change proposal; do not claim that
files were already written and do not perform review, validation or approval.

Workshop input JSON:
${jsonEncode(payload)}

Return ONLY one JSON object with this exact contract:
{
  "summary": "optional short summary",
  "explanation": "required non-empty explanation",
  "analysis": "optional implementation analysis",
  "changes": [
    {
      "path": "workspace/relative/path",
      "type": "addition|modification|deletion",
      "content": "required full file content for addition/modification"
    }
  ],
  "validationNotes": ["optional validation note"],
  "warnings": ["optional warning"]
}

For deletion omit content. Paths must be workspace-relative. Return full file
content for every addition or modification. Do not return markdown fences or
any text outside the JSON object.
'''.trim();
  }

  static const String _systemPrompt =
      'You are the Engineer brain of the Cantiere. Implement only the supplied '
      'Workshop task using the workspace snapshot and, when present, the '
      'supplied Cantiere preflight guidance and authoritative semantic resume '
      'state. Continue from verified prior work instead of restarting it. Do '
      'not use or assume Assistant chat memory, configuration or model '
      'selection. Return only the required structured change proposal and '
      'never mutate the real repository directly.';
}
