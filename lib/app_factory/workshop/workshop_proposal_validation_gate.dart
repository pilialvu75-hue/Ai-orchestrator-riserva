import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

/// Structured validation verdict for a staged Workshop proposal.
///
/// Validation is intentionally separate from approval. A successful verdict
/// keeps the session in [WorkspaceSessionStatus.validation]; a later explicit
/// approval is still required before the real workspace can be mutated.
final class WorkshopValidationVerdict {
  const WorkshopValidationVerdict({
    required this.valid,
    required this.summary,
    this.checks = const <String>[],
    this.warnings = const <String>[],
  });

  final bool valid;
  final String summary;
  final List<String> checks;
  final List<String> warnings;
}

/// Decodes the validation-stage Reviewer response without bypassing the
/// existing approval/apply guardrails in [WorkspaceSession].
///
/// Accepted payload:
/// {
///   "valid": true,
///   "summary": "validation passed",
///   "checks": ["..."],
///   "warnings": ["..."]
/// }
///
/// A valid verdict leaves the session in validation and does not call
/// approveApply() or apply(). A rejected verdict blocks the session.
final class WorkshopProposalValidationGate {
  const WorkshopProposalValidationGate();

  WorkshopValidationVerdict evaluate({
    required WorkspaceSession session,
    required String responseText,
  }) {
    if (session.status != WorkspaceSessionStatus.validation) {
      throw StateError(
        'Workshop validation can only be evaluated while the workspace '
        'session is in validation. Current status: ${session.status.name}.',
      );
    }

    final verdict = _decode(responseText);

    if (!verdict.valid) {
      session.block(
        verdict.summary.isEmpty
            ? 'Workshop validation rejected the staged proposal.'
            : verdict.summary,
      );
    }

    return verdict;
  }

  WorkshopValidationVerdict _decode(String responseText) {
    final normalized = responseText.trim();
    if (normalized.isEmpty) {
      throw const FormatException(
        'Workshop validation response cannot be empty.',
      );
    }

    final fenced = RegExp(
      r'^```(?:json)?\s*([\s\S]*?)\s*```$',
      caseSensitive: false,
    ).firstMatch(normalized);

    final decoded = jsonDecode((fenced?.group(1) ?? normalized).trim());
    if (decoded is! Map) {
      throw const FormatException(
        'Workshop validation response must be a JSON object.',
      );
    }

    final payload = Map<String, dynamic>.from(decoded);
    final valid = payload['valid'];
    if (valid is! bool) {
      throw const FormatException(
        'Workshop validation field "valid" must be a boolean.',
      );
    }

    final summaryValue = payload['summary'];
    if (summaryValue is! String || summaryValue.trim().isEmpty) {
      throw const FormatException(
        'Workshop validation field "summary" is required.',
      );
    }

    return WorkshopValidationVerdict(
      valid: valid,
      summary: summaryValue.trim(),
      checks: _stringList(payload, 'checks'),
      warnings: _stringList(payload, 'warnings'),
    );
  }

  List<String> _stringList(
    Map<String, dynamic> payload,
    String key,
  ) {
    final value = payload[key];
    if (value == null) {
      return const <String>[];
    }
    if (value is! List || value.any((item) => item is! String)) {
      throw FormatException(
        'Workshop validation field "$key" must be a list of strings.',
      );
    }

    return List<String>.unmodifiable(
      value
          .cast<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty),
    );
  }
}
