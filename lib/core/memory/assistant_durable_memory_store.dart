import 'dart:convert';

import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';

abstract class AssistantDurableMemoryPersistence {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SqliteAssistantDurableMemoryPersistence
    implements AssistantDurableMemoryPersistence {
  const SqliteAssistantDurableMemoryPersistence({
    required DatabaseHelper databaseHelper,
  }) : _databaseHelper = databaseHelper;

  final DatabaseHelper _databaseHelper;

  @override
  Future<String?> read(String key) => _databaseHelper.getPreference(key);

  @override
  Future<void> write(String key, String value) =>
      _databaseHelper.setPreference(key, value);
}

/// Local-first durable memory store.
///
/// This layer owns persistence and validation only. It deliberately does not
/// decide what the model should remember. Production writers must provide
/// deterministic/verified records; model-generated candidates remain
/// [AssistantMemoryStatus.candidate] until explicitly promoted.
class AssistantDurableMemoryStore {
  const AssistantDurableMemoryStore({
    required AssistantDurableMemoryPersistence persistence,
  }) : _persistence = persistence;

  static const String _storagePrefix = 'assistant.durable_memory.v1:';

  final AssistantDurableMemoryPersistence _persistence;

  Future<List<AssistantDurableMemoryRecord>> load({
    required AssistantMemoryScope scope,
    required String scopeId,
    bool confirmedOnly = true,
  }) async {
    final normalizedScopeId = scopeId.trim();
    if (normalizedScopeId.isEmpty) return const [];

    final raw = await _persistence.read(_storageKey(scope, normalizedScopeId));
    if (raw == null || raw.trim().isEmpty) return const [];

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];

    final records = <AssistantDurableMemoryRecord>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final map = <String, Object?>{
        for (final entry in item.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
      final record = AssistantDurableMemoryRecord.tryFromJson(map);
      if (record == null) continue;
      if (record.scope != scope || record.scopeId != normalizedScopeId) continue;
      if (confirmedOnly && record.status != AssistantMemoryStatus.confirmed) {
        continue;
      }
      records.add(record);
    }

    records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<AssistantDurableMemoryRecord>.unmodifiable(
      records.take(AssistantDurableMemoryPolicy.maxRecordsPerScope),
    );
  }

  Future<void> upsert(AssistantDurableMemoryRecord record) async {
    final normalized = _validateAndNormalize(record);
    final existing = await load(
      scope: normalized.scope,
      scopeId: normalized.scopeId,
      confirmedOnly: false,
    );

    final next = <AssistantDurableMemoryRecord>[
      normalized,
      ...existing.where((item) => item.recordKey != normalized.recordKey),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    await _write(
      normalized.scope,
      normalized.scopeId,
      next.take(AssistantDurableMemoryPolicy.maxRecordsPerScope).toList(),
    );
  }

  Future<bool> confirm({
    required AssistantMemoryScope scope,
    required String scopeId,
    required String recordKey,
    required int confirmedAt,
  }) async {
    final records = await load(
      scope: scope,
      scopeId: scopeId,
      confirmedOnly: false,
    );
    final index = records.indexWhere((item) => item.recordKey == recordKey);
    if (index < 0) return false;

    final next = records.toList(growable: true);
    next[index] = _validateAndNormalize(
      next[index].copyWith(
        status: AssistantMemoryStatus.confirmed,
        updatedAt: confirmedAt,
      ),
    );
    next.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _write(scope, scopeId.trim(), next);
    return true;
  }

  Future<bool> remove({
    required AssistantMemoryScope scope,
    required String scopeId,
    required String recordKey,
  }) async {
    final records = await load(
      scope: scope,
      scopeId: scopeId,
      confirmedOnly: false,
    );
    final next =
        records.where((item) => item.recordKey != recordKey).toList();
    if (next.length == records.length) return false;
    await _write(scope, scopeId.trim(), next);
    return true;
  }

  Future<void> _write(
    AssistantMemoryScope scope,
    String scopeId,
    List<AssistantDurableMemoryRecord> records,
  ) {
    final payload = jsonEncode(
      records
          .take(AssistantDurableMemoryPolicy.maxRecordsPerScope)
          .map((item) => item.toJson())
          .toList(growable: false),
    );
    return _persistence.write(_storageKey(scope, scopeId), payload);
  }

  AssistantDurableMemoryRecord _validateAndNormalize(
    AssistantDurableMemoryRecord record,
  ) {
    final key = record.recordKey.trim();
    final scopeId = record.scopeId.trim();
    final content = record.content.trim();
    final source = record.source.trim();
    final before = _nullableTrim(record.before);
    final after = _nullableTrim(record.after);
    final reason = _nullableTrim(record.reason);

    _requireBounded('recordKey', key, AssistantDurableMemoryPolicy.maxKeyChars);
    _requireBounded(
      'scopeId',
      scopeId,
      AssistantDurableMemoryPolicy.maxScopeIdChars,
    );
    _requireBounded(
      'content',
      content,
      AssistantDurableMemoryPolicy.maxContentChars,
    );
    _requireBounded(
      'source',
      source,
      AssistantDurableMemoryPolicy.maxSourceChars,
    );
    _requireOptionalBounded('before', before);
    _requireOptionalBounded('after', after);
    _requireOptionalBounded('reason', reason);

    if (record.updatedAt < 0) {
      throw ArgumentError.value(record.updatedAt, 'updatedAt');
    }

    return AssistantDurableMemoryRecord(
      recordKey: key,
      scope: record.scope,
      scopeId: scopeId,
      kind: record.kind,
      content: content,
      source: source,
      updatedAt: record.updatedAt,
      status: record.status,
      before: before,
      after: after,
      reason: reason,
    );
  }

  void _requireBounded(String name, String value, int maxChars) {
    if (value.isEmpty || value.length > maxChars) {
      throw ArgumentError.value(value, name, 'must be 1..$maxChars chars');
    }
  }

  void _requireOptionalBounded(String name, String? value) {
    if (value != null &&
        value.length > AssistantDurableMemoryPolicy.maxTransitionFieldChars) {
      throw ArgumentError.value(
        value,
        name,
        'must be <= ${AssistantDurableMemoryPolicy.maxTransitionFieldChars} chars',
      );
    }
  }

  String? _nullableTrim(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  String _storageKey(AssistantMemoryScope scope, String scopeId) =>
      '$_storagePrefix${scope.name}:${Uri.encodeComponent(scopeId)}';
}
