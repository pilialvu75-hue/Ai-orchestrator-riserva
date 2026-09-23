import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_provider.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_record.dart';
import 'package:ai_orchestrator/core/sync/crdt/crdt_record.dart';
import 'package:ai_orchestrator/core/sync/sync_manager.dart';

/// Local/offline Memory Fabric node backed by the existing SQLite CRDT journal.
///
/// No new database is introduced. [SyncManager] remains responsible for local
/// persistence and HLC/LWW transport semantics; this adapter adds canonical
/// Memory Fabric version/checksum guards and query semantics.
final class LocalCrdtMemoryFabricProvider implements MemoryFabricProvider {
  LocalCrdtMemoryFabricProvider({
    required SyncManager syncManager,
    String providerId = 'local_crdt',
  })  : _syncManager = syncManager,
        descriptor = MemoryFabricProviderDescriptor(
          providerId: providerId,
          location: 'device',
          allowedPrivacy: Set<MemoryFabricPrivacyLevel>.of(
            MemoryFabricPrivacyLevel.values,
          ),
          durable: true,
        ) {
    _syncManager.registerCollectionConflictResolver(
      collection,
      _resolveRemoteConflict,
    );
  }

  static const String collection = 'memory_fabric_v1';

  final SyncManager _syncManager;

  @override
  final MemoryFabricProviderDescriptor descriptor;

  @override
  Future<MemoryFabricRecord> write(MemoryFabricRecord record) async {
    final existing = await read(record.id);
    if (existing != null) {
      if (record.version < existing.version) {
        throw StateError(
          'Memory version regression for ${record.id}: '
          '${record.version} < ${existing.version}',
        );
      }
      if (record.version == existing.version &&
          record.checksum != existing.checksum) {
        throw StateError(
          'Same-version checksum conflict for '
          '${record.id} v${record.version}',
        );
      }
    }

    await _syncManager.recordChange(
      collection: collection,
      key: record.id,
      value: Map<String, dynamic>.from(record.toJson()),
    );
    return record;
  }

  @override
  Future<MemoryFabricRecord?> read(String recordId) async {
    final raw = await _syncManager.getRecord(collection, recordId);
    if (raw == null) return null;
    return _decode(raw);
  }

  @override
  Future<List<MemoryFabricRecord>> search(MemoryFabricQuery query) async {
    final rawRecords = await _syncManager.getCollection(collection);
    final records = <MemoryFabricRecord>[];

    for (final raw in rawRecords) {
      final record = _decode(raw);
      if (record == null) continue;
      if (!_matches(record, query)) continue;
      records.add(record);
    }

    records.sort((left, right) {
      final timestamp = right.updatedAt.compareTo(left.updatedAt);
      if (timestamp != 0) return timestamp;
      return right.version.compareTo(left.version);
    });

    return List<MemoryFabricRecord>.unmodifiable(
      records.take(query.limit),
    );
  }

  @override
  Future<MemoryFabricSyncReport> sync() async {
    final maxHlc = await _syncManager.maxHlc();
    final changeCount = await _syncManager.changeCount();
    return MemoryFabricSyncReport(
      providerId: descriptor.providerId,
      ok: true,
      details: <String, Object?>{
        'mode': 'local_crdt_ready',
        'node_id': _syncManager.nodeId,
        'max_hlc': maxHlc,
        'change_count': changeCount,
      },
    );
  }

  @override
  Future<MemoryFabricHealth> health() async {
    final checkedAt = DateTime.now().toUtc();
    try {
      final maxHlc = await _syncManager.maxHlc();
      final changeCount = await _syncManager.changeCount();
      return MemoryFabricHealth(
        providerId: descriptor.providerId,
        status: MemoryFabricHealthStatus.healthy,
        readable: true,
        writable: true,
        checkedAt: checkedAt,
        details: <String, Object?>{
          'node_id': _syncManager.nodeId,
          'max_hlc': maxHlc,
          'change_count': changeCount,
        },
      );
    } on Object catch (error) {
      return MemoryFabricHealth(
        providerId: descriptor.providerId,
        status: MemoryFabricHealthStatus.unavailable,
        readable: false,
        writable: false,
        checkedAt: checkedAt,
        details: <String, Object?>{'error': error.toString()},
      );
    }
  }

  static SyncConflictResolution _resolveRemoteConflict(
    CrdtRecord? existing,
    CrdtRecord incoming,
  ) {
    if (incoming.isTombstone) {
      return SyncConflictResolution.keepExisting;
    }

    final incomingRecord = _decodeCrdtRecord(incoming);
    if (incomingRecord == null || !incomingRecord.checksumValid) {
      return SyncConflictResolution.keepExisting;
    }

    if (existing == null) {
      return SyncConflictResolution.preferIncoming;
    }

    final existingRecord = _decodeCrdtRecord(existing);
    if (existingRecord == null || !existingRecord.checksumValid) {
      return SyncConflictResolution.preferIncoming;
    }

    if (incomingRecord.version > existingRecord.version) {
      return SyncConflictResolution.preferIncoming;
    }
    if (incomingRecord.version < existingRecord.version) {
      return SyncConflictResolution.keepExisting;
    }

    if (incomingRecord.checksum != existingRecord.checksum) {
      return SyncConflictResolution.keepExisting;
    }

    return SyncConflictResolution.useDefaultLww;
  }

  static MemoryFabricRecord? _decodeCrdtRecord(CrdtRecord record) {
    final raw = record.decodedValue;
    if (raw == null) return null;
    try {
      return MemoryFabricRecord.fromJson(
        Map<String, Object?>.from(raw),
      );
    } on Object {
      return null;
    }
  }

  MemoryFabricRecord? _decode(Map<String, dynamic> raw) {
    try {
      return MemoryFabricRecord.fromJson(
        Map<String, Object?>.from(raw),
      );
    } on Object {
      return null;
    }
  }

  bool _matches(MemoryFabricRecord record, MemoryFabricQuery query) {
    if (!query.includeExpired && record.isExpired()) return false;
    if (!record.checksumValid) return false;

    if (query.namespace != null && record.namespace != query.namespace) {
      return false;
    }
    if (query.types.isNotEmpty && !query.types.contains(record.type)) {
      return false;
    }
    if (query.subject != null && record.subject != query.subject) {
      return false;
    }
    if (query.projectId != null && record.projectId != query.projectId) {
      return false;
    }
    if (query.userId != null && record.userId != query.userId) {
      return false;
    }
    if (query.agentId != null && record.agentId != query.agentId) {
      return false;
    }
    if (query.conversationId != null &&
        record.conversationId != query.conversationId) {
      return false;
    }

    final updatedAfter = query.updatedAfter?.toUtc();
    if (updatedAfter != null && record.updatedAt.isBefore(updatedAfter)) {
      return false;
    }
    final updatedBefore = query.updatedBefore?.toUtc();
    if (updatedBefore != null && record.updatedAt.isAfter(updatedBefore)) {
      return false;
    }

    if (query.tags.isNotEmpty) {
      final tags = record.tags.toSet();
      if (!query.tags.every(tags.contains)) return false;
    }

    final text = query.text?.trim().toLowerCase();
    if (text != null &&
        text.isNotEmpty &&
        !record.subject.toLowerCase().contains(text) &&
        !record.content.toLowerCase().contains(text)) {
      return false;
    }

    return true;
  }
}
