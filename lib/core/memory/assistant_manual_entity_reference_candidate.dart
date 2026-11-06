import 'dart:convert';

import 'package:ai_orchestrator/core/memory/assistant_entity_reference_analyzer.dart';

/// Only a manually submitted, named claim can enter the review queue.
///
/// The encoded *statement* is the key, not the name: two people named Jerome
/// must never become a single immutable person identity by matching aliases.
/// The reversible key is not a secret; all durable memory stays local.
abstract final class AssistantManualEntityReferenceCandidate {
  static const String keyPrefix = 'natural.entity.statement.';

  static String? recordKeyFor(String userText) {
    final claim =
        AssistantEntityReferenceAnalyzer.parseDirectUserStatement(userText);
    if (claim == null ||
        claim.subjectKind != AssistantEntityReferenceKind.person ||
        claim.namedReference == null ||
        claim.claimKind == AssistantEntityClaimKind.opinion) {
      return null;
    }
    final normalized = claim.userStatement.toLowerCase();
    final encoded = base64Url.encode(utf8.encode(normalized)).replaceAll('=', '');
    final key = '$keyPrefix$encoded';
    return key.length <= 160 ? key : null;
  }
}
