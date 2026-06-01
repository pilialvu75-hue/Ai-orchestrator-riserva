import 'package:ai_orchestrator/core/sync/crdt/crdt_record.dart';
import 'package:ai_orchestrator/core/sync/crdt/hlc.dart';

/// In-memory Last-Write-Wins (LWW) CRDT document.
///
/// A [CrdtDocument] stores one [CrdtRecord] per `(collection, key)` pair,
/// keeping the record with the highest [Hlc] timestamp. This is the core
/// conflict-resolution strategy: the "last write wins" based on the causal
/// ordering of HLC timestamps.
///
/// Typical usage:
/// ```dart
/// final doc = CrdtDocument(nodeId: 'device-uuid');
/// doc.put('chat_history', messageId, jsonEncode(message.toMap()), clock);
/// doc.merge(remoteDoc);
/// final messages = doc.entriesFor('chat_history');
/// ```
class CrdtDocument {
  CrdtDocument({required String nodeId})
      : _nodeId = nodeId,
        _clock = Hlc.zero(nodeId);

  final String _nodeId;
  Hlc _clock;

  /// Current logical clock for this node.
  Hlc get clock => _clock;

  /// Internal storage: `collection → key → CrdtRecord`.
  final Map<String, Map<String, CrdtRecord>> _store = {};

  // ── Mutations ─────────────────────────────────────────────────────────────

  /// Writes a new record and advances the local clock.
  ///
  /// [collection] and [key] identify the record; [jsonValue] is the JSON-
  /// encoded content. Passing an empty [jsonValue] creates a tombstone.
  CrdtRecord put(
    String collection,
    String key,
    String jsonValue,
    String recordId,
  ) {
    _clock = Hlc.send(_clock);
    final record = CrdtRecord(
      id: recordId,
      collection: collection,
      key: key,
      value: jsonValue,
      hlc: _clock,
      nodeId: _nodeId,
    );
    _applyRecord(record);
    return record;
  }

  /// Creates a tombstone (marks [key] as deleted) in [collection].
  CrdtRecord delete(String collection, String key, String recordId) =>
      put(collection, key, '', recordId);

  // ── Querying ──────────────────────────────────────────────────────────────

  /// Returns the winning record for the given [collection] and [key], or
  /// `null` if no record exists (or it was deleted / tombstoned).
  CrdtRecord? get(String collection, String key) {
    final entry = _store[collection]?[key];
    if (entry == null || entry.isTombstone) return null;
    return entry;
  }

  /// Returns all non-tombstone records in [collection].
  List<CrdtRecord> entriesFor(String collection) {
    final bucket = _store[collection];
    if (bucket == null) return const [];
    return bucket.values.where((r) => !r.isTombstone).toList();
  }

  /// Returns every record (including tombstones) in [collection].
  List<CrdtRecord> allEntriesFor(String collection) =>
      _store[collection]?.values.toList() ?? const [];

  // ── Merging ───────────────────────────────────────────────────────────────

  /// Merges [incoming] records into this document.
  ///
  /// Each record is applied only when its causal HLC time (wall time +
  /// counter) is strictly greater than the existing record for the same key
  /// (LWW). The local clock is advanced to remain causally consistent.
  void merge(List<CrdtRecord> incoming) {
    for (final record in incoming) {
      _clock = Hlc.recv(_clock, record.hlc);
      _applyRecord(record);
    }
  }

  /// Returns the list of all records with an HLC strictly greater than [since].
  ///
  /// Used to produce a changeset for a sync peer.
  List<CrdtRecord> changesSince(Hlc since) {
    final result = <CrdtRecord>[];
    for (final bucket in _store.values) {
      for (final record in bucket.values) {
        if (record.hlc.compareCausalTo(since) > 0) result.add(record);
      }
    }
    result.sort((a, b) => a.hlc.compareTo(b.hlc));
    return result;
  }

  /// All records stored in this document (includes tombstones).
  List<CrdtRecord> get allRecords {
    final result = <CrdtRecord>[];
    for (final bucket in _store.values) {
      result.addAll(bucket.values);
    }
    return result;
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _applyRecord(CrdtRecord record) {
    final bucket = _store.putIfAbsent(record.collection, () => {});
    final existing = bucket[record.key];
    if (existing == null || record.hlc.compareCausalTo(existing.hlc) > 0) {
      bucket[record.key] = record;
    }
  }
}
