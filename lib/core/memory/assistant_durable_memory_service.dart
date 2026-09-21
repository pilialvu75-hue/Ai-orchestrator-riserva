import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';

/// Deterministic application-facing gateway for durable Assistant memory.
///
/// This service deliberately keeps memory policy above model/provider code:
/// callers must provide an explicit logical key and scope. Model output can be
/// stored only as a candidate and never becomes confirmed without an external
/// confirmation source.
class AssistantDurableMemoryService {
  const AssistantDurableMemoryService({
    required AssistantDurableMemoryStore store,
  }) : _store = store;

  static const int defaultReadLimit = 8;

  final AssistantDurableMemoryStore _store;

  Future<void> recordConfirmed({
    required String recordKey,
    required AssistantMemoryScope scope,
    required String scopeId,
    required AssistantMemoryKind kind,
    required String content,
    required AssistantMemorySource source,
    required int updatedAt,
    String? before,
    String? after,
    String? reason,
  }) {
    if (source == AssistantMemorySource.modelCandidate) {
      throw ArgumentError(
        'Confirmed durable memory requires a non-model confirmation source.',
      );
    }

    return _store.upsert(
      AssistantDurableMemoryRecord(
        recordKey: recordKey,
        scope: scope,
        scopeId: scopeId,
        kind: kind,
        content: content,
        source: source,
        updatedAt: updatedAt,
        status: AssistantMemoryStatus.confirmed,
        before: before,
        after: after,
        reason: reason,
      ),
    );
  }

  Future<void> recordModelCandidate({
    required String recordKey,
    required AssistantMemoryScope scope,
    required String scopeId,
    required AssistantMemoryKind kind,
    required String content,
    required int updatedAt,
    String? before,
    String? after,
    String? reason,
  }) {
    return _store.upsert(
      AssistantDurableMemoryRecord(
        recordKey: recordKey,
        scope: scope,
        scopeId: scopeId,
        kind: kind,
        content: content,
        source: AssistantMemorySource.modelCandidate,
        updatedAt: updatedAt,
        status: AssistantMemoryStatus.candidate,
        before: before,
        after: after,
        reason: reason,
      ),
    );
  }

  Future<bool> confirmCandidate({
    required AssistantMemoryScope scope,
    required String scopeId,
    required String recordKey,
    required int confirmedAt,
    required AssistantMemorySource confirmedSource,
  }) {
    if (confirmedSource == AssistantMemorySource.modelCandidate) {
      throw ArgumentError(
        'Candidate confirmation requires an external confirmation source.',
      );
    }

    return _store.confirm(
      scope: scope,
      scopeId: scopeId,
      recordKey: recordKey,
      confirmedAt: confirmedAt,
      confirmedSource: confirmedSource,
    );
  }

  Future<List<AssistantDurableMemoryRecord>> loadConfirmed({
    required AssistantMemoryScope scope,
    required String scopeId,
    int limit = defaultReadLimit,
  }) async {
    if (limit <= 0) {
      return const <AssistantDurableMemoryRecord>[];
    }

    final records = await _store.load(
      scope: scope,
      scopeId: scopeId,
      confirmedOnly: true,
    );

    return List<AssistantDurableMemoryRecord>.unmodifiable(
      records.take(limit),
    );
  }

  Future<bool> remove({
    required AssistantMemoryScope scope,
    required String scopeId,
    required String recordKey,
  }) {
    return _store.remove(
      scope: scope,
      scopeId: scopeId,
      recordKey: recordKey,
    );
  }
}
