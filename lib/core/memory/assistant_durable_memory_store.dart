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
  AssistantDurableMemoryStore({
    required AssistantDurableMemoryPersistence persistence,
  }) : _persistence = persistence;

  static const String storagePrefix = 'assistant.durable_memory.v1:';

  final AssistantDurableMemoryPersistence _persistence;

  // Serialize read-modify-write operations by scope within the production
  // singleton. A single JSON preference contains all records for a scope;
  // overlapping updates otherwise overwrite each other. This is deliberately
  // local-only: it does not enable distributed synchronization.
  final Map<String, Future<void>> _pendingScopeWrites = <String, Future<void>>{};

  Future<T> _withScopeWriteLock<T>(
    AssistantMemoryScope scope,
    String scopeId,
    Future<T> Function() action,
  ) {
    final key = _storageKey(scope, scopeId);
    final predecessor = _pendingScopeWrites[key] ?? Future<void>.value();
    final result = predecessor.then((_) => action());

    // A failed write must fail its own caller, but must not poison the next
    // write in this scope. Remove an idle tail so the map cannot grow forever.
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _pendingScopeWrites[key] = tail;
    tail.then((_) {
      if (identical(_pendingScopeWrites[key], tail)) {
        _pendingScopeWrites.remove(key);
      }
    });
    return result;
  }


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
      final parsed = AssistantDurableMemoryRecord.tryFromJson(map);
      if (parsed == null) continue;

      AssistantDurableMemoryRecord record;
      try {
        record = _validateAndNormalize(parsed);
      } on ArgumentError {
        continue;
      }

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
    await _withScopeWriteLock(
      normalized.scope,
      normalized.scopeId,
      () async {
        final existing = await load(
          scope: normalized.scope,
          scopeId: normalized.scopeId,
          confirmedOnly: false,
        );

        // A tentative suggestion must never replace an accepted fact
        // with the same logical key, even if it has a newer timestamp.
        // Out-of-order tentative callbacks must not replace newer drafts.
        if (normalized.status == AssistantMemoryStatus.candidate) {
          for (final previous in existing) {
            if (previous.recordKey == normalized.recordKey &&
                (previous.status == AssistantMemoryStatus.confirmed ||
                 previous.updatedAt > normalized.updatedAt)) {
              return;
            }
          }
        }

        final next = <AssistantDurableMemoryRecord>[
          normalized,
          ...existing.where((item) => item.recordKey != normalized.recordKey),
        ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

        // A stream of unconfirmed suggestions must not evict established
        // memories from the bounded per-scope SQLite record set.
        final accepted = next
            .where((item) => item.status == AssistantMemoryStatus.confirmed)
            .take(AssistantDurableMemoryPolicy.maxRecordsPerScope)
            .toList();
        final pending = next
            .where((item) => item.status == AssistantMemoryStatus.candidate)
            .take(AssistantDurableMemoryPolicy.maxRecordsPerScope -
                accepted.length);
        final bounded = <AssistantDurableMemoryRecord>[
          ...accepted,
          ...pending,
        ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

        await _write(
          normalized.scope,
          normalized.scopeId,
          bounded,
        );
      },
    );
  }

  /// Atomically resolve the exact user-stated proposal shown for review.
  ///
  /// A stale decision, unrelated/model candidate or already-confirmed record
  /// must not be modified. The same per-scope queue protects concurrent
  /// proposal updates and review actions in this store instance.
  Future<bool> resolveUserStatementCandidate({
    required AssistantDurableMemoryRecord reviewed,
    required bool approve,
    required int reviewedAt,
    String? approvedContent,
  }) async {
    if (reviewed.scope != AssistantMemoryScope.user ||
        reviewed.status != AssistantMemoryStatus.candidate ||
        reviewed.source != AssistantMemorySource.userStatement ||
        reviewed.kind != AssistantMemoryKind.preference ||
        reviewedAt < 0 ||
        (approve && (approvedContent == null ||
            approvedContent.trim().isEmpty))) {
      return false;
    }

    final scopeId = reviewed.scopeId.trim();
    if (scopeId.isEmpty) return false;

    return _withScopeWriteLock(reviewed.scope, scopeId, () async {
      final records = await load(
        scope: reviewed.scope,
        scopeId: scopeId,
        confirmedOnly: false,
      );
      final index = records.indexWhere(
        (item) => item.recordKey == reviewed.recordKey,
      );
      if (index < 0) return false;

      final current = records[index];
      if (current.status != AssistantMemoryStatus.candidate ||
          current.source != AssistantMemorySource.userStatement ||
          current.kind != AssistantMemoryKind.preference ||
          current.updatedAt != reviewed.updatedAt ||
          current.content != reviewed.content ||
          reviewedAt < current.updatedAt) {
        return false;
      }

      final next = records.toList(growable: true);
      if (approve) {
        next[index] = _validateAndNormalize(current.copyWith(
          status: AssistantMemoryStatus.confirmed,
          source: AssistantMemorySource.userExplicit,
          content: approvedContent!.trim(),
          updatedAt: reviewedAt,
        ));
      } else {
        next.removeAt(index);
      }
      next.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _write(reviewed.scope, scopeId, next);
      return true;
    });
  }

  Future<bool> confirm({
    required AssistantMemoryScope scope,
    required String scopeId,
    required String recordKey,
    required int confirmedAt,
    required AssistantMemorySource confirmedSource,
  }) async {
    if (confirmedSource == AssistantMemorySource.modelCandidate) {
      throw ArgumentError(
        'confirmedSource must represent an external confirmation',
      );
    }

    final normalizedScopeId = scopeId.trim();
    return await _withScopeWriteLock(scope, normalizedScopeId, () async {
      final records = await load(
        scope: scope,
        scopeId: normalizedScopeId,
        confirmedOnly: false,
      );
      final index = records.indexWhere((item) => item.recordKey == recordKey);
      if (index < 0) return false;

      final next = records.toList(growable: true);
      next[index] = _validateAndNormalize(
        next[index].copyWith(
          status: AssistantMemoryStatus.confirmed,
          source: confirmedSource,
          updatedAt: confirmedAt,
        ),
      );
      next.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _write(scope, normalizedScopeId, next);
      return true;
    });
  }

  Future<bool> remove({
    required AssistantMemoryScope scope,
    required String scopeId,
    required String recordKey,
  }) async {
    final normalizedScopeId = scopeId.trim();
    return _withScopeWriteLock(scope, normalizedScopeId, () async {
      final records = await load(
        scope: scope,
        scopeId: normalizedScopeId,
        confirmedOnly: false,
      );
      final next =
          records.where((item) => item.recordKey != recordKey).toList();
      if (next.length == records.length) return false;
      await _write(scope, normalizedScopeId, next);
      return true;
    });
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
    _requireOptionalBounded('before', before);
    _requireOptionalBounded('after', after);
    _requireOptionalBounded('reason', reason);

    if (record.updatedAt < 0) {
      throw ArgumentError.value(record.updatedAt, 'updatedAt');
    }
    if (record.status == AssistantMemoryStatus.confirmed &&
        (record.source == AssistantMemorySource.modelCandidate ||
         record.source == AssistantMemorySource.userStatement)) {
      throw ArgumentError(
        'Tentative/model memories cannot be persisted as confirmed.',
      );
    }

    return AssistantDurableMemoryRecord(
      recordKey: key,
      scope: record.scope,
      scopeId: scopeId,
      kind: record.kind,
      content: content,
      source: record.source,
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
      '$storagePrefix${scope.name}:${Uri.encodeComponent(scopeId)}';
}
