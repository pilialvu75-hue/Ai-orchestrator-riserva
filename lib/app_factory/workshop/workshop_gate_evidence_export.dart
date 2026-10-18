import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';

/// Explicit, local-only export of the rejected staged proposal.
///
/// This never writes to Diagnostics or a repository. The owner chooses whether
/// to copy or share the source evidence. Content is never silently truncated.
abstract final class WorkshopGateEvidenceExport {
  static const int maxExportChars = 300000;

  /// Privacy-safe reason to display when source export cannot be completed.
  ///
  /// Do not interpolate arbitrary exception messages here: they may contain
  /// source snippets, local paths or task identifiers.
  static String failureExplanation(Object error) {
    if (error is StateError) {
      switch (error.message) {
        case 'Gate evidence does not match the active project task.':
          return 'Evidenze non riferite al task attivo. Riapri il progetto '
              'originale prima di riprovare la copia.';
        case 'Gate evidence is available only for rejected gates.':
          return 'Il task non ha un gate respinto da esportare.';
        case 'Rejected gate source snapshot is not available.':
          return 'Snapshot del codice respinto non disponibile. '
              'Il report accettazione resta utilizzabile.';
        case 'Rejected gate evidence contains unrelated file paths.':
          return 'I file delle evidenze non corrispondono alla proposta: '
              'esportazione bloccata per sicurezza.';
        case 'Rejected gate source evidence has incomplete coverage.':
          return 'Snapshot delle modifiche incompleto: esportazione '
              'bloccata per evitare codice parziale.';
        case 'Gate evidence exceeds the safe clipboard size; no partial source was copied.':
          return 'Codice troppo grande per gli appunti: nessuna copia '
              'parziale eseguita.';
      }
    }
    return 'Esportazione non riuscita. Nessun codice sorgente copiato; '
        'usa il report accettazione e segnala il problema.';
  }

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
