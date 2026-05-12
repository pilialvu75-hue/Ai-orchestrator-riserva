import 'dart:convert';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/sync/crdt/crdt_document.dart';
import 'package:ai_orchestrator/core/sync/crdt/crdt_record.dart';
import 'package:ai_orchestrator/core/sync/crdt/hlc.dart';
import 'package:uuid/uuid.dart';

/// High-level coordinator for the local-first CRDT sync layer.
///
/// [SyncManager] bridges the in-memory [CrdtDocument] and the SQLite
/// `sync_changes` table:
///
/// * **Track writes** – every time the app modifies chat history or project
///   memory, call [recordChange] so a CRDT record is stored locally.
/// * **Export** – call [exportChangesSince] to obtain a changeset for a
///   sync peer.
/// * **Import** – call [applyRemoteChangeset] when receiving a changeset from
///   a peer; the LWW rules in [CrdtDocument.merge] resolve conflicts
///   automatically.
///
/// The manager is designed to remain fully functional **without network
/// access** – all reads and writes target the local SQLite database first.
class SyncManager {
  SyncManager({
    required DatabaseHelper databaseHelper,
    required String nodeId,
  })  : _db = databaseHelper,
        _nodeId = nodeId,
        _document = CrdtDocument(nodeId: nodeId);

  final DatabaseHelper _db;
  final String _nodeId;
  final CrdtDocument _document;
  final _uuid = const Uuid();

  bool _loaded = false;

  /// Unique identifier for this device / installation.
  String get nodeId => _nodeId;

  // ── Initialization ────────────────────────────────────────────────────────

  /// Loads all previously persisted changes from SQLite into the in-memory
  /// [CrdtDocument].  Must be awaited before using other methods.
  Future<void> load() async {
    if (_loaded) return;
    final rows = await _db.getSyncChangesSince(Hlc.zero(_nodeId).toString());
    final records = rows.map(CrdtRecord.fromMap).toList();
    _document.merge(records);
    _loaded = true;
  }

  // ── Write path ────────────────────────────────────────────────────────────

  /// Records a change to [collection] / [key] with the given JSON [value].
  ///
  /// Persists the change to SQLite and updates the in-memory document.
  /// Call this whenever the app creates or updates a record that should
  /// participate in CRDT sync (e.g. a chat message or project memory entry).
  Future<CrdtRecord> recordChange({
    required String collection,
    required String key,
    required Map<String, dynamic> value,
  }) async {
    await _ensureLoaded();
    final jsonValue = jsonEncode(value);
    final recordId = _uuid.v4();
    final record = _document.put(collection, key, jsonValue, recordId);
    await _persistRecord(record);
    return record;
  }

  /// Records a deletion (tombstone) for [collection] / [key].
  Future<CrdtRecord> recordDeletion({
    required String collection,
    required String key,
  }) async {
    await _ensureLoaded();
    final recordId = _uuid.v4();
    final record = _document.delete(collection, key, recordId);
    await _persistRecord(record);
    return record;
  }

  // ── Sync export/import ────────────────────────────────────────────────────

  /// Returns all records changed after [sinceHlc] as a JSON-serialisable list.
  ///
  /// The resulting list is intended to be sent to a sync peer (e.g. via the
  /// [LocalSyncServer]).  Pass `null` to export the full document state.
  Future<List<Map<String, dynamic>>> exportChangesSince([
    String? sinceHlc,
  ]) async {
    await _ensureLoaded();
    final since = sinceHlc != null ? Hlc.parse(sinceHlc) : Hlc.zero(_nodeId);
    final changes = _document.changesSince(since);
    return changes.map((r) => r.toJson()).toList();
  }

  /// Applies a list of CRDT records received from a remote peer.
  ///
  /// Merges them into the in-memory document (LWW conflict resolution) and
  /// persists any records that are newer than what we already have.
  Future<int> applyRemoteChangeset(List<Map<String, dynamic>> changeset) async {
    await _ensureLoaded();
    var applied = 0;
    for (final json in changeset) {
      final record = CrdtRecord.fromJson(json);
      final existing = _document.get(record.collection, record.key);
      // Only persist if this record wins the LWW race.
      if (existing == null || record.hlc > existing.hlc) {
        _document.merge([record]);
        await _persistRecord(record);
        applied++;
      }
    }
    return applied;
  }

  // ── Query ─────────────────────────────────────────────────────────────────

  /// Returns the current winning value for [collection] / [key], or null if
  /// the record doesn't exist or was deleted.
  Future<Map<String, dynamic>?> getRecord(
    String collection,
    String key,
  ) async {
    await _ensureLoaded();
    return _document.get(collection, key)?.decodedValue;
  }

  /// Returns all non-tombstone records in [collection].
  Future<List<Map<String, dynamic>>> getCollection(String collection) async {
    await _ensureLoaded();
    return _document
        .entriesFor(collection)
        .map((r) => r.decodedValue ?? <String, dynamic>{})
        .where((m) => m.isNotEmpty)
        .toList();
  }

  /// The current maximum HLC string for this node (useful as a cursor for
  /// incremental sync: peers can request changes since this value).
  Future<String?> maxHlc() async {
    await _ensureLoaded();
    return _db.getMaxSyncHlc();
  }

  /// Total number of change records stored locally.
  Future<int> changeCount() => _db.countSyncChanges();

  // ── Private ───────────────────────────────────────────────────────────────

  Future<void> _ensureLoaded() async {
    if (!_loaded) await load();
  }

  Future<void> _persistRecord(CrdtRecord record) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.insertSyncChange(record.toMap(now));
  }
}

/// Known CRDT collection names.
///
/// Using constants avoids typos when calling [SyncManager.recordChange].
abstract class SyncCollections {
  SyncCollections._();

  static const String chatHistory =
      AppConstants.tableChatHistory; // 'chat_history'
  static const String projectMemory =
      AppConstants.tableProjectMemory; // 'project_memory'
  static const String userPreferences =
      AppConstants.tableUserPreferences; // 'user_preferences'
}
