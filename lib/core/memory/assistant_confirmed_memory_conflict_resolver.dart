import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_entity_reference_analyzer.dart';

/// Canonical view of already-confirmed memory, independent of any LLM.
///
/// This class is deliberately read-only. It cannot confirm a candidate,
/// infer an identity, write a fact, or silently delete older stored history.
abstract final class AssistantConfirmedMemoryConflictResolver {
  /// Only an owner-reviewed, explicitly confirmed replacement can shadow a
  /// distinct, previously confirmed named claim.
  static const String reviewedCorrectionReason =
      'owner_reviewed_entity_replacement:v1';
  static const String correctionKeyPrefix = 'reviewed.entity.correction.';

  /// Logical record identity includes scope and scopeId: equal text keys in
  /// another conversation or in global user memory are NOT identity proof.
  /// Only duplicate versions of the same fully scoped key are deduplicated.
  ///
  /// Two different keys are never merged merely because their wording,
  /// predicates, aliases or attributes look alike.
  static List<AssistantDurableMemoryRecord> currentView({
    required List<AssistantDurableMemoryRecord> conversationRecords,
    required List<AssistantDurableMemoryRecord> userRecords,
  }) {
    final byKey =
        <(AssistantMemoryScope, String, String), AssistantDurableMemoryRecord>{};
    for (final record in <AssistantDurableMemoryRecord>[
      ...conversationRecords,
      ...userRecords,
    ]) {
      if (record.status != AssistantMemoryStatus.confirmed) continue;
      final scopedKey = (record.scope, record.scopeId, record.recordKey);
      final existing = byKey[scopedKey];
      if (existing == null || record.updatedAt > existing.updatedAt) {
        byKey[scopedKey] = record;
      }
    }

    final records = byKey.values.toList(growable: false);
    final replaced = <(AssistantMemoryScope, String, String)>{};
    for (final correction in records) {
      if (!isReviewedNamedCorrection(correction)) continue;
      final matchingOlder = records.where((earlier) =>
          earlier.recordKey != correction.recordKey &&
          earlier.scope == correction.scope &&
          earlier.scopeId == correction.scopeId &&
          earlier.updatedAt < correction.updatedAt &&
          _normalized(earlier.content) ==
              _normalized(correction.before!)).toList(growable: false);
      // Two people sharing a name may have identical text records. Exact
      // wording is NOT identity proof: reject ambiguous replacements.
      if (matchingOlder.length == 1) {
        // Keep SQLite history intact; hide only the superseded rendering.
        final old = matchingOlder.single;
        replaced.add((old.scope, old.scopeId, old.recordKey));
      }
    }
    return List<AssistantDurableMemoryRecord>.unmodifiable(
      records.where((record) =>
          !replaced.contains((record.scope, record.scopeId, record.recordKey))),
    );
  }

  /// Explicitly authored, reviewed before -> after replacement only.
  /// Parsing both sides prevents a renamed person or a loose word match
  /// from becoming an identity inference or an automatic correction.
  static bool isReviewedNamedCorrection(AssistantDurableMemoryRecord record) {
    if (record.status != AssistantMemoryStatus.confirmed ||
        record.source != AssistantMemorySource.userExplicit ||
        record.kind != AssistantMemoryKind.fact ||
        record.reason != reviewedCorrectionReason ||
        !record.recordKey.startsWith(correctionKeyPrefix) ||
        record.before == null ||
        record.after == null ||
        _normalized(record.before!) == _normalized(record.after!) ||
        _normalized(record.after!) != _normalized(record.content)) {
      return false;
    }
    final before = AssistantEntityReferenceAnalyzer.parseDirectUserStatement(
      record.before!,
    );
    final after = AssistantEntityReferenceAnalyzer.parseDirectUserStatement(
      record.after!,
    );
    return before != null &&
        after != null &&
        before.subjectKind == AssistantEntityReferenceKind.person &&
        after.subjectKind == AssistantEntityReferenceKind.person &&
        before.nameReferenceKey != null &&
        after.nameReferenceKey != null &&
        before.predicate == after.predicate &&
        before.value == after.value &&
        before.claimKind == after.claimKind;
  }

  /// A reviewed third-party correction cannot enter a broad 'about me'
  /// context: its named referent must be mentioned explicitly by the query.
  static Set<String> namedReferencesForCorrection(
      AssistantDurableMemoryRecord record) {
    if (!isReviewedNamedCorrection(record)) return const <String>{};
    final before = AssistantEntityReferenceAnalyzer.parseDirectUserStatement(
      record.before!,
    )!;
    final after = AssistantEntityReferenceAnalyzer.parseDirectUserStatement(
      record.after!,
    )!;
    return <String>{
      before.namedReference!.toLowerCase(),
      after.namedReference!.toLowerCase(),
    };
  }

  static String _normalized(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}
