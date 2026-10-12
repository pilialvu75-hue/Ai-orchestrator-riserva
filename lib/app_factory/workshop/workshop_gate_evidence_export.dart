import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';

/// Explicit, local-only export of the rejected staged proposal.
///
/// This never writes to Diagnostics or a repository. The owner chooses whether
/// to copy or share the source evidence. Content is never silently truncated.
abstract final class WorkshopGateEvidenceExport {
  static const int maxExportChars = 300000;

  static String encode({
    required String projectId,
    required String taskRequestId,
    required WorkshopTaskInferenceResult result,
  }) {
    if (projectId.trim().isEmpty ||
        taskRequestId.trim().isEmpty ||
        result.proposal.requestId != taskRequestId) {
      throw StateError('Gate evidence does not match the active project task.');
    }
    final reviewRejected = !result.review.approved;
    final validationRejected = result.validation?.valid == false;
    if (!reviewRejected && !validationRejected) {
      throw StateError('Gate evidence is available only for rejected gates.');
    }
    // The actual staged workspace is the source of truth for Review, not the
    // model's potentially stale/tampered proposal transport envelope.
    final before = result.gateEvidenceBaseline;
    final after = result.gateEvidenceStaged;
    if (before == null || after == null) {
      throw StateError('Rejected gate source snapshot is not available.');
    }
    final expectedPaths = result.proposal.affectedPaths.toSet();
    if (expectedPaths.isEmpty ||
        {...before.keys, ...after.keys}.difference(expectedPaths).isNotEmpty) {
      throw StateError('Rejected gate evidence contains unrelated file paths.');
    }
    final changes = WorkspaceDiff.compare(before: before, after: after).changes;
    if (changes.isEmpty ||
        changes.map((change) => change.path).toSet().length !=
            expectedPaths.length ||
        !expectedPaths.containsAll(changes.map((change) => change.path))) {
      throw StateError('Rejected gate source evidence has incomplete coverage.');
    }

    final payload = <String, Object?>{
      'schemaVersion': 1,
      'projectId': projectId,
      'taskRequestId': taskRequestId,
      'source': 'staged_virtual_workspace',
      'failureGate': reviewRejected ? 'review' : 'validation',
      'reviewApproved': result.review.approved,
      'reviewSummary': result.review.summary,
      'reviewFindings': result.review.findings,
      'reviewWarnings': result.review.warnings,
      'validationValid': result.validation?.valid,
      if (result.validation != null)
        'validationSummary': result.validation!.summary,
      if (result.validation != null)
        'validationChecks': result.validation!.checks,
      'changes': <Map<String, Object?>>[
        for (final change in changes)
          <String, Object?>{
            'path': change.path,
            'type': change.type.name,
            'before': change.beforeContent,
            'after': change.afterContent,
          },
      ],
    };
    final encoded = const JsonEncoder.withIndent('  ').convert(payload);
    if (encoded.length > maxExportChars) {
      throw StateError(
        'Gate evidence exceeds the safe clipboard size; no partial source was copied.',
      );
    }
    return encoded;
  }
}
