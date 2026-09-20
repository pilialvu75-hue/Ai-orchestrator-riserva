import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_workspace_proposal_applier.dart';

final class WorkshopAirLabStagedFile {
  const WorkshopAirLabStagedFile._({required this.exists, this.content});
  const WorkshopAirLabStagedFile.missing() : this._(exists: false);
  const WorkshopAirLabStagedFile.present(String content)
      : this._(exists: true, content: content);
  final bool exists;
  final String? content;
}

abstract interface class WorkshopAirLabStagingReader {
  Future<WorkshopAirLabStagedFile> inspect({
    required String stagingRoot,
    required String relativePath,
  });
}

final class WorkshopAirLabPromotionException implements Exception {
  const WorkshopAirLabPromotionException(this.message,
      {required this.code, this.path});
  final String message;
  final String code;
  final String? path;
  @override
  String toString() => 'WorkshopAirLabPromotionException($code): $message';
}

final class WorkshopAirLabWorkspacePromotionResult {
  const WorkshopAirLabWorkspacePromotionResult({
    required this.proposal,
    required this.requestId,
    required this.engineId,
  });
  final WorkshopChangeProposal proposal;
  final String requestId;
  final String engineId;
  List<String> get changedFiles => proposal.affectedPaths;
  int get additions => proposal.additions;
  int get modifications => proposal.modifications;
  int get deletions => proposal.deletions;
}

/// Promotes validated AIrLab staging into VirtualWorkspace only.
/// Real-workspace mutation remains behind review, validation and explicit apply.
final class WorkshopAirLabWorkspacePromoter {
  const WorkshopAirLabWorkspacePromoter({
    WorkshopWorkspaceProposalApplier applier =
        const WorkshopWorkspaceProposalApplier(),
    this.maxChangedFiles = 64,
  }) : _applier = applier;

  final WorkshopWorkspaceProposalApplier _applier;
  final int maxChangedFiles;

  Future<WorkshopAirLabWorkspacePromotionResult> promote({
    required WorkspaceSession session,
    required WorkshopTaskExecutionResult executionResult,
    required String stagingRoot,
    required WorkshopAirLabStagingReader reader,
  }) async {
    final provenance = _validateBoundary(
      session: session,
      executionResult: executionResult,
      stagingRoot: stagingRoot,
    );
    final changedPaths = <String>[];
    final seen = <String>{};
    for (final rawPath in executionResult.changedFiles) {
      final path = _normalizeRelativePath(rawPath);
      if (!seen.add(path)) {
        throw WorkshopAirLabPromotionException(
          'AIrLab promotion contains a duplicate changed path.',
          code: 'duplicate_changed_path', path: path);
      }
      changedPaths.add(path);
    }
    if (changedPaths.isEmpty) {
      throw const WorkshopAirLabPromotionException(
        'AIrLab promotion requires at least one staged changed file.',
        code: 'changed_files_empty');
    }
    if (changedPaths.length > maxChangedFiles) {
      throw WorkshopAirLabPromotionException(
        'AIrLab promotion exceeds the changed-file limit of $maxChangedFiles.',
        code: 'changed_file_limit_exceeded');
    }
    final checkpointPaths = executionResult.checkpoint!.changedFiles
        .map(_normalizeRelativePath).toSet();
    if (checkpointPaths.length != changedPaths.length ||
        !checkpointPaths.containsAll(changedPaths)) {
      throw const WorkshopAirLabPromotionException(
        'AIrLab result and checkpoint disagree about staged changed files.',
        code: 'changed_files_provenance_mismatch');
    }
    final declaredOperationCount = executionResult.metadata['operationCount'];
    if (declaredOperationCount is! int ||
        declaredOperationCount != changedPaths.length) {
      throw const WorkshopAirLabPromotionException(
        'AIrLab staged operation count does not match changed files.',
        code: 'operation_count_mismatch');
    }

    // Validate/read the whole staged set before mutating VirtualWorkspace.
    final staged = <String, WorkshopAirLabStagedFile>{};
    for (final path in changedPaths) {
      staged[path] = await reader.inspect(
        stagingRoot: stagingRoot, relativePath: path);
    }
    final changes = <WorkspaceFileChange>[];
    for (final path in changedPaths) {
      final stagedFile = staged[path]!;
      final workspaceContains = session.workspace.contains(path);
      final before = session.workspace.read(path);
      if (stagedFile.exists) {
        final after = stagedFile.content;
        if (after == null) {
          throw WorkshopAirLabPromotionException(
            'AIrLab staged file exists but has no readable text content.',
            code: 'staged_content_missing', path: path);
        }
        if (workspaceContains) {
          if (before == after) {
            throw WorkshopAirLabPromotionException(
              'AIrLab marked a file as changed but staging matches the workspace.',
              code: 'staged_change_noop', path: path);
          }
          changes.add(WorkspaceFileChange(
            path: path,
            type: WorkspaceChangeType.modification,
            beforeContent: before,
            afterContent: after));
        } else {
          changes.add(WorkspaceFileChange(
            path: path,
            type: WorkspaceChangeType.addition,
            afterContent: after));
        }
      } else {
        if (!workspaceContains) {
          throw WorkshopAirLabPromotionException(
            'AIrLab changed path is absent from both staging and workspace.',
            code: 'staged_change_missing', path: path);
        }
        changes.add(WorkspaceFileChange(
          path: path,
          type: WorkspaceChangeType.deletion,
          beforeContent: before));
      }
    }

    final proposal = WorkshopChangeProposal(
      requestId: session.context.request.id,
      summary: 'AIrLab staged changes ready for Cantiere review',
      explanation:
          'Validated AIrLab staging was promoted into VirtualWorkspace only. '
          'The real workspace still requires normal review, validation and '
          'explicit owner approval before apply.',
      changes: List<WorkspaceFileChange>.unmodifiable(changes),
      validationNotes: <String>[
        'AIrLab request_id=${provenance.requestId}',
        'AIrLab engine_id=${provenance.engineId}',
        'Workshop task_id=${executionResult.taskId}',
      ]);
    _applier.applyProposal(session: session, proposal: proposal);
    session.beginReview();
    return WorkshopAirLabWorkspacePromotionResult(
      proposal: proposal,
      requestId: provenance.requestId,
      engineId: provenance.engineId);
  }

  _PromotionProvenance _validateBoundary({
    required WorkspaceSession session,
    required WorkshopTaskExecutionResult executionResult,
    required String stagingRoot,
  }) {
    if (stagingRoot.trim().isEmpty) {
      throw const WorkshopAirLabPromotionException(
        'Cantiere staging root is empty.', code: 'staging_root_invalid');
    }
    if (!session.workspace.isInitialized) {
      throw const WorkshopAirLabPromotionException(
        'WorkspaceSession must be initialized before AIrLab promotion.',
        code: 'workspace_not_initialized');
    }
    if (session.status != WorkspaceSessionStatus.ready &&
        session.status != WorkspaceSessionStatus.working) {
      throw WorkshopAirLabPromotionException(
        'AIrLab promotion requires a ready/working WorkspaceSession; '
        'current status is ${session.status.name}.',
        code: 'workspace_status_invalid');
    }
    if (session.hasChanges) {
      throw const WorkshopAirLabPromotionException(
        'AIrLab promotion requires a clean VirtualWorkspace baseline.',
        code: 'workspace_not_clean');
    }
    if (!executionResult.requiresApproval) {
      throw const WorkshopAirLabPromotionException(
        'Only AIrLab results awaiting approval can enter promotion.',
        code: 'execution_status_invalid');
    }
    if (executionResult.metadata['executor'] != 'airlab' ||
        executionResult.metadata['stagingOnly'] != true ||
        executionResult.metadata['promotionRequired'] != true ||
        executionResult.metadata['repositoryModified'] != false) {
      throw const WorkshopAirLabPromotionException(
        'Execution result is not a controlled staging-only AIrLab result.',
        code: 'execution_boundary_invalid');
    }
    final checkpoint = executionResult.checkpoint;
    if (checkpoint == null ||
        checkpoint.phase != 'airlab-staged-awaiting-approval') {
      throw const WorkshopAirLabPromotionException(
        'AIrLab staging checkpoint is missing or has an invalid phase.',
        code: 'checkpoint_invalid');
    }
    if (checkpoint.metadata['stagingOnly'] != true ||
        checkpoint.metadata['repositoryModified'] != false ||
        checkpoint.metadata['task_id'] != executionResult.taskId) {
      throw const WorkshopAirLabPromotionException(
        'AIrLab checkpoint provenance does not match the execution result.',
        code: 'checkpoint_provenance_invalid');
    }
    final requestId = checkpoint.metadata['request_id'];
    final engineId = checkpoint.metadata['engine_id'];
    if (requestId is! String || requestId.trim().isEmpty ||
        engineId is! String || engineId.trim().isEmpty) {
      throw const WorkshopAirLabPromotionException(
        'AIrLab checkpoint request/engine provenance is missing.',
        code: 'checkpoint_provenance_missing');
    }
    return _PromotionProvenance(
      requestId: requestId.trim(), engineId: engineId.trim());
  }
}

final class _PromotionProvenance {
  const _PromotionProvenance({required this.requestId, required this.engineId});
  final String requestId;
  final String engineId;
}

String _normalizeRelativePath(String rawPath) {
  final value = rawPath.trim().replaceAll('\\', '/');
  if (value.isEmpty) {
    throw const WorkshopAirLabPromotionException(
      'AIrLab promotion path is empty.', code: 'empty_path');
  }
  if (value.contains('\u0000')) {
    throw WorkshopAirLabPromotionException(
      'AIrLab promotion path contains a null byte.',
      code: 'invalid_path', path: rawPath);
  }
  if (value.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(value)) {
    throw WorkshopAirLabPromotionException(
      'AIrLab promotion path must be relative.',
      code: 'absolute_path_forbidden', path: rawPath);
  }
  final segments = value.split('/');
  if (segments.any((segment) =>
      segment.isEmpty || segment == '.' || segment == '..')) {
    throw WorkshopAirLabPromotionException(
      'AIrLab promotion path contains traversal or empty segments.',
      code: 'path_traversal', path: rawPath);
  }
  return segments.join('/');
}
