import 'dart:convert';

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
    final changes = result.proposal.changes.toList(growable: false)
      ..sort((left, right) => left.path.compareTo(right.path));
    if (changes.isEmpty) {
      throw StateError('The rejected proposal has no file changes to export.');
    }

    final payload = <String, Object?>{
      'schemaVersion': 1,
      'projectId': projectId,
      'taskRequestId': taskRequestId,
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
