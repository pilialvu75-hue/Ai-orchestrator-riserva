import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ai_orchestrator/core/memory/assistant_entity_reference_analyzer.dart';

/// Parsed from an explicit direct-user correction. Not an identity proof,
/// approval, a persistent record, or permission to send facts to Cloud.
final class AssistantNamedRelationCorrectionDraft {
  const AssistantNamedRelationCorrectionDraft({
    required this.originalStatement,
    required this.beforeFact,
    required this.afterFact,
  });

  final String originalStatement;
  final String beforeFact;
  final String afterFact;

  String get recordKey => AssistantNamedRelationCorrectionCandidate
      .recordKeyFor(this);
}

/// Small, closed Italian correction vocabulary; no AI extraction.
/// A third-party assertion must remain a review-only candidate.
abstract final class AssistantNamedRelationCorrectionCandidate {
  static const String pendingReason = 'direct_named_correction_candidate:it';

  static final RegExp _directReplacement = RegExp(
    r'^non\s+([\p{L}\p{M}\x27’-]+)\s*,\s*'
    r'([\p{L}\p{M}\x27’-]+)\s+(è alto|fa tanto sport)[.!]?$',
    caseSensitive: false,
    unicode: true,
  );
  static final RegExp _tallReassignment = RegExp(
    r'^non\s+è\s+([\p{L}\p{M}\x27’-]+)\s+a\s+essere\s+'
    r'alto\s*,\s*ma\s+([\p{L}\p{M}\x27’-]+)[.!]?$',
    caseSensitive: false,
    unicode: true,
  );

  static AssistantNamedRelationCorrectionDraft? parse(String input) {
    final text = input.trim();
    if (text.isEmpty ||
        text.length > 120 ||
        text.contains('\n') ||
        text.contains('\r') ||
        text.contains('://') ||
        text.contains('@') ||
        text.contains('"') ||
        text.contains('?')) {
      return null;
    }
    final generic = _directReplacement.firstMatch(text);
    final tall = generic == null ? _tallReassignment.firstMatch(text) : null;
    if (generic == null && tall == null) return null;
    final match = generic ?? tall!;
    final beforeName = match.group(1)!.trim();
    final afterName = match.group(2)!.trim();
    final predicate = generic != null ? generic.group(3)!.toLowerCase() : 'è alto';

    final beforeFact = '$beforeName $predicate.';
    final afterFact = '$afterName $predicate.';
    final before =
        AssistantEntityReferenceAnalyzer.parseDirectUserStatement(beforeFact);
    final after =
        AssistantEntityReferenceAnalyzer.parseDirectUserStatement(afterFact);
    if (before == null ||
        after == null ||
        before.nameReferenceKey == null ||
        after.nameReferenceKey == null ||
        before.nameReferenceKey == after.nameReferenceKey ||
        before.predicate != after.predicate ||
        before.value != after.value) {
      return null;
    }
    return AssistantNamedRelationCorrectionDraft(
      originalStatement: text,
      beforeFact: beforeFact,
      afterFact: afterFact,
    );
  }

  static String recordKeyFor(AssistantNamedRelationCorrectionDraft draft) {
    final key = utf8.encode('${draft.beforeFact}\u0000${draft.afterFact}');
    return 'reviewed.entity.correction.${sha256.convert(key)}';
  }
}
