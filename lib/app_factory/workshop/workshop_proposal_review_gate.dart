import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_structured_json.dart';

/// Structured Reviewer verdict for a staged Workshop proposal.
///
/// This object is intentionally side-effect free. It only represents the
/// Reviewer's decision; the real repository remains protected by the later
/// validation, approval and apply gates in [WorkspaceSession].
final class WorkshopReviewVerdict {
  const WorkshopReviewVerdict({
    required this.approved,
    required this.summary,
    this.findings = const <String>[],
    this.warnings = const <String>[],
  });

  final bool approved;
  final String summary;
  final List<String> findings;
  final List<String> warnings;
}

/// Decodes a structured Reviewer response and advances the WorkspaceSession
/// only when the review explicitly approves the staged proposal.
///
/// Accepted payload:
/// {
///   "approved": true,
///   "summary": "review passed",
///   "findings": ["..."],
///   "warnings": ["..."]
/// }
///
/// Approval moves the existing session from review -> validation.
/// Rejection blocks the session. No write/commit/push/PR operation is issued.
final class WorkshopProposalReviewGate {
  const WorkshopProposalReviewGate();

  WorkshopReviewVerdict evaluate({
    required WorkspaceSession session,
    required String responseText,
  }) {
    final verdict = decode(responseText);
    applyVerdict(session: session, verdict: verdict);
    return verdict;
  }

  /// Decodes one Reviewer response without mutating the workspace session.
  ///
  /// Batch-aware runners use this to collect complete review coverage before a
  /// single aggregate verdict is allowed to advance the session.
  WorkshopReviewVerdict decode(String responseText) => _decode(responseText);

  /// Applies one already-decoded aggregate verdict to the review gate.
  void applyVerdict({
    required WorkspaceSession session,
    required WorkshopReviewVerdict verdict,
  }) {
    if (session.status != WorkspaceSessionStatus.review) {
      throw StateError(
        'Workshop review can only be evaluated while the workspace session '
        'is in review. Current status: ${session.status.name}.',
      );
    }

    if (verdict.approved) {
      session.beginValidation();
    } else {
      session.block(
        verdict.summary.isEmpty
            ? 'Workshop reviewer rejected the staged proposal.'
            : verdict.summary,
      );
    }
  }

  WorkshopReviewVerdict _decode(String responseText) {
    final jsonText = WorkshopStructuredJson.extractObjectText(
      responseText,
      emptyMessage: 'Workshop reviewer response cannot be empty.',
    );

    dynamic decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      final repaired =
          WorkshopStructuredJson.repairMalformedContentStrings(jsonText);
      if (repaired == null) {
        rethrow;
      }
      decoded = jsonDecode(repaired);
    }

    if (decoded is! Map) {
      throw const FormatException(
        'Workshop reviewer response must be a JSON object.',
      );
    }

    final payload = Map<String, dynamic>.from(decoded);
    final approved = payload['approved'];
    if (approved is! bool) {
      throw const FormatException(
        'Workshop reviewer field "approved" must be a boolean.',
      );
    }

    final summaryValue = payload['summary'];
    if (summaryValue is! String || summaryValue.trim().isEmpty) {
      throw const FormatException(
        'Workshop reviewer field "summary" is required.',
      );
    }

    return WorkshopReviewVerdict(
      approved: approved,
      summary: summaryValue.trim(),
      findings: _stringList(payload, 'findings'),
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
        'Workshop reviewer field "$key" must be a list of strings.',
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
