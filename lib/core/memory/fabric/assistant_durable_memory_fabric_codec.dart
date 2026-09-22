import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:uuid/uuid.dart';

import 'memory_fabric_record.dart';

/// Pure compatibility codec for the durable Assistant memory that already
/// exists in AI-Orchestrator.
///
/// This codec never reads/writes storage. Existing durable memory remains
/// authoritative until a provider adapter is deliberately wired later.
///
/// Privacy is DEVICE_ONLY by default so introducing Memory Fabric cannot
/// silently upload existing personal/project memory to a cloud node.
abstract final class AssistantDurableMemoryFabricCodec {
  static const String namespace = 'ai-orchestrator.assistant_durable';

  static MemoryFabricRecord toFabric(
    AssistantDurableMemoryRecord source, {
    MemoryFabricPrivacyLevel privacyLevel =
        MemoryFabricPrivacyLevel.deviceOnly,
    double confidence = 1.0,
  }) {
    final timestamp =
        DateTime.fromMillisecondsSinceEpoch(source.updatedAt, isUtc: true);
    final scopeId = source.scopeId.trim();
    final recordKey = source.recordKey.trim();

    return MemoryFabricRecord.create(
      id: const Uuid().v5(
        Namespace.url.value,
        'assistant-durable:${source.scope.name}:$scopeId:$recordKey',
      ),
      namespace: namespace,
      type: _typeFor(source),
      subject: recordKey,
      content: source.content,
      source: 'legacy_assistant:${source.source.name}',
      structuredData: <String, Object?>{
        'assistant_scope': source.scope.name,
        'assistant_scope_id': scopeId,
        'assistant_kind': source.kind.name,
        'assistant_status': source.status.name,
        'assistant_source': source.source.name,
        if (source.before != null) 'before': source.before,
        if (source.after != null) 'after': source.after,
        if (source.reason != null) 'reason': source.reason,
      },
      confidence: confidence,
      now: timestamp,
      privacyLevel: privacyLevel,
      tags: <String>[
        'assistant_durable',
        source.kind.name,
        source.status.name,
      ],
      projectId:
          source.scope == AssistantMemoryScope.project ? scopeId : null,
      userId: source.scope == AssistantMemoryScope.user ? scopeId : null,
      conversationId:
          source.scope == AssistantMemoryScope.conversation ? scopeId : null,
    );
  }

  static AssistantDurableMemoryRecord? tryFromFabric(
    MemoryFabricRecord record,
  ) {
    if (record.namespace != namespace) return null;
    final data = record.structuredData;
    final scope = _scope(data['assistant_scope']);
    final kind = _kind(data['assistant_kind']);
    final status = _status(data['assistant_status']);
    final source = _source(data['assistant_source']);
    final scopeId = data['assistant_scope_id']?.toString().trim() ?? '';

    if (scope == null ||
        kind == null ||
        status == null ||
        source == null ||
        scopeId.isEmpty ||
        record.subject.trim().isEmpty) {
      return null;
    }

    return AssistantDurableMemoryRecord(
      recordKey: record.subject.trim(),
      scope: scope,
      scopeId: scopeId,
      kind: kind,
      content: record.content,
      source: source,
      updatedAt: record.updatedAt.millisecondsSinceEpoch,
      status: status,
      before: _optional(data['before']),
      after: _optional(data['after']),
      reason: _optional(data['reason']),
    );
  }

  static MemoryFabricType _typeFor(AssistantDurableMemoryRecord record) {
    return switch (record.kind) {
      AssistantMemoryKind.fact => MemoryFabricType.longTermFact,
      AssistantMemoryKind.preference => MemoryFabricType.userPreference,
      AssistantMemoryKind.decision => MemoryFabricType.decisionLog,
      AssistantMemoryKind.state when record.scope == AssistantMemoryScope.project =>
        MemoryFabricType.project,
      AssistantMemoryKind.unresolvedTask
          when record.scope == AssistantMemoryScope.project =>
        MemoryFabricType.project,
      AssistantMemoryKind.state ||
      AssistantMemoryKind.transition ||
      AssistantMemoryKind.unresolvedTask =>
        MemoryFabricType.episodic,
    };
  }

  static AssistantMemoryScope? _scope(Object? value) {
    final name = value?.toString();
    for (final item in AssistantMemoryScope.values) {
      if (item.name == name) return item;
    }
    return null;
  }

  static AssistantMemoryKind? _kind(Object? value) {
    final name = value?.toString();
    for (final item in AssistantMemoryKind.values) {
      if (item.name == name) return item;
    }
    return null;
  }

  static AssistantMemoryStatus? _status(Object? value) {
    final name = value?.toString();
    for (final item in AssistantMemoryStatus.values) {
      if (item.name == name) return item;
    }
    return null;
  }

  static AssistantMemorySource? _source(Object? value) {
    final name = value?.toString();
    for (final item in AssistantMemorySource.values) {
      if (item.name == name) return item;
    }
    return null;
  }

  static String? _optional(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
