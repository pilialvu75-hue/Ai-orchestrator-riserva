import 'dart:convert';

import 'package:ai_orchestrator/core/sync/crdt/hlc.dart';

/// A single change record in the CRDT change log.
///
/// Each record represents a mutation to a specific (collection, key) pair.
/// The [hlc] timestamp makes the record causally ordered; the Last-Write-Wins
/// rule selects the winner when two records target the same key.
class CrdtRecord {
  const CrdtRecord({
    required this.id,
    required this.collection,
    required this.key,
    required this.value,
    required this.hlc,
    required this.nodeId,
  });

  /// Unique UUID for this change record (used as primary key in SQLite).
  final String id;

  /// Logical collection name, e.g. `"chat_history"` or `"project_memory"`.
  final String collection;

  /// Record key within the collection, e.g. a chat message UUID.
  final String key;

  /// JSON-encoded value of the record (empty string = tombstone / deleted).
  final String value;

  /// HLC timestamp string for causal ordering.
  final Hlc hlc;

  /// Node (device) ID that produced this change.
  final String nodeId;

  // ── Convenience ──────────────────────────────────────────────────────────

  /// Whether this record represents a deletion (tombstone).
  bool get isTombstone => value.isEmpty;

  /// Decodes [value] as a JSON map. Returns null for tombstones.
  Map<String, dynamic>? get decodedValue {
    if (isTombstone) return null;
    try {
      return jsonDecode(value) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  // ── Serialisation ────────────────────────────────────────────────────────

  factory CrdtRecord.fromMap(Map<String, dynamic> map) {
    return CrdtRecord(
      id: map['sync_id'] as String,
      collection: map['collection'] as String,
      key: map['record_key'] as String,
      value: map['record_value'] as String? ?? '',
      hlc: Hlc.parse(map['hlc'] as String),
      nodeId: map['node_id'] as String,
    );
  }

  Map<String, dynamic> toMap(int timestampMs) => {
        'sync_id': id,
        'collection': collection,
        'record_key': key,
        'record_value': value,
        'hlc': hlc.toString(),
        'node_id': nodeId,
        'applied': 1,
        'timestamp': timestampMs,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'collection': collection,
        'key': key,
        'value': value,
        'hlc': hlc.toString(),
        'nodeId': nodeId,
      };

  factory CrdtRecord.fromJson(Map<String, dynamic> json) {
    return CrdtRecord(
      id: json['id'] as String,
      collection: json['collection'] as String,
      key: json['key'] as String,
      value: json['value'] as String? ?? '',
      hlc: Hlc.parse(json['hlc'] as String),
      nodeId: json['nodeId'] as String,
    );
  }

  @override
  String toString() =>
      'CrdtRecord(collection=$collection, key=$key, hlc=$hlc, nodeId=$nodeId)';
}
