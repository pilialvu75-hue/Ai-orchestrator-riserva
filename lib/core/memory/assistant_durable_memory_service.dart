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
    if (source == AssistantMemorySource.modelCandidate ||
        source == AssistantMemorySource.userStatement) {
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

  /// User-originated suggestion, not an instruction to remember permanently.
  ///
  /// The suggestion stays invisible to confirmed-memory retrieval until
  /// a separate, explicit user review confirms it.
  Future<void> recordUserCandidate({
    required String recordKey,
    required AssistantMemoryScope scope,
    required String scopeId,
    required AssistantMemoryKind kind,
    required String content,
    required int updatedAt,
  }) {
    return _store.upsert(
      AssistantDurableMemoryRecord(
        recordKey: recordKey,
        scope: scope,
        scopeId: scopeId,
        kind: kind,
        content: content,
        source: AssistantMemorySource.userStatement,
        updatedAt: updatedAt,
        status: AssistantMemoryStatus.candidate,
      ),
    );
  }

  /// Review-only read; ordinary inference must continue using loadConfirmed.
  Future<List<AssistantDurableMemoryRecord>> loadCandidates({
    required AssistantMemoryScope scope,
    required String scopeId,
    int limit = defaultReadLimit,
  }) async {
    if (limit <= 0) return const <AssistantDurableMemoryRecord>[];
    final records = await _store.load(
      scope: scope,
      scopeId: scopeId,
      confirmedOnly: false,
    );
    return List<AssistantDurableMemoryRecord>.unmodifiable(
      records.where((item) => item.status == AssistantMemoryStatus.candidate)
          .take(limit),
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

  /// Review a specific user-stated candidate snapshot; never a model guess.
  ///
  /// The store compares the snapshot with current SQLite content inside its
  /// per-scope write queue before approving, correcting or rejecting it.
  Future<bool> resolveUserStatementCandidate({
    required AssistantDurableMemoryRecord reviewed,
    required bool approve,
    required int reviewedAt,
    String? approvedContent,
  }) {
    return _store.resolveUserStatementCandidate(
      reviewed: reviewed,
      approve: approve,
      reviewedAt: reviewedAt,
      approvedContent: approvedContent,
    );
  }

  Future<bool> confirmCandidate({
    required AssistantMemoryScope scope,
    required String scopeId,
    required String recordKey,
    required int confirmedAt,
    required AssistantMemorySource confirmedSource,
  }) {
    if (confirmedSource == AssistantMemorySource.modelCandidate ||
        confirmedSource == AssistantMemorySource.userStatement) {
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
