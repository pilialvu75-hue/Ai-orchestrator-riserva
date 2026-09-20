enum AssistantMemoryScope {
  user,
  project,
  conversation,
}

enum AssistantMemoryKind {
  fact,
  preference,
  decision,
  state,
  transition,
  unresolvedTask,
}

enum AssistantMemoryStatus {
  candidate,
  confirmed,
}

/// Compact durable fact/state retained above the model/provider layer.
///
/// Durable memories are deliberately structured and bounded. Raw chat logs,
/// provider traces and large model outputs do not belong in this record.
class AssistantDurableMemoryRecord {
  const AssistantDurableMemoryRecord({
    required this.recordKey,
    required this.scope,
    required this.scopeId,
    required this.kind,
    required this.content,
    required this.source,
    required this.updatedAt,
    this.status = AssistantMemoryStatus.candidate,
    this.before,
    this.after,
    this.reason,
  });

  /// Stable logical identity. Upserting the same key replaces older state.
  final String recordKey;
  final AssistantMemoryScope scope;
  final String scopeId;
  final AssistantMemoryKind kind;
  final String content;

  /// Closed or deterministic source label such as "user_explicit",
  /// "verified_test" or "app_state".
  final String source;
  final int updatedAt;
  final AssistantMemoryStatus status;

  /// Optional transition details. These make "before -> after + reason"
  /// available without storing verbose logs.
  final String? before;
  final String? after;
  final String? reason;

  AssistantDurableMemoryRecord copyWith({
    String? recordKey,
    AssistantMemoryScope? scope,
    String? scopeId,
    AssistantMemoryKind? kind,
    String? content,
    String? source,
    int? updatedAt,
    AssistantMemoryStatus? status,
    String? before,
    String? after,
    String? reason,
  }) {
    return AssistantDurableMemoryRecord(
      recordKey: recordKey ?? this.recordKey,
      scope: scope ?? this.scope,
      scopeId: scopeId ?? this.scopeId,
      kind: kind ?? this.kind,
      content: content ?? this.content,
      source: source ?? this.source,
      updatedAt: updatedAt ?? this.updatedAt,
      status: status ?? this.status,
      before: before ?? this.before,
      after: after ?? this.after,
      reason: reason ?? this.reason,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'recordKey': recordKey,
        'scope': scope.name,
        'scopeId': scopeId,
        'kind': kind.name,
        'content': content,
        'source': source,
        'updatedAt': updatedAt,
        'status': status.name,
        if (before != null) 'before': before,
        if (after != null) 'after': after,
        if (reason != null) 'reason': reason,
      };

  static AssistantDurableMemoryRecord? tryFromJson(
    Map<String, Object?> json,
  ) {
    final recordKey = json['recordKey'];
    final scopeName = json['scope'];
    final scopeId = json['scopeId'];
    final kindName = json['kind'];
    final content = json['content'];
    final source = json['source'];
    final updatedAt = json['updatedAt'];
    final statusName = json['status'];

    if (recordKey is! String ||
        scopeName is! String ||
        scopeId is! String ||
        kindName is! String ||
        content is! String ||
        source is! String ||
        updatedAt is! num ||
        statusName is! String) {
      return null;
    }

    final scope = _enumByName(AssistantMemoryScope.values, scopeName);
    final kind = _enumByName(AssistantMemoryKind.values, kindName);
    final status = _enumByName(AssistantMemoryStatus.values, statusName);

    if (scope == null || kind == null || status == null) {
      return null;
    }

    return AssistantDurableMemoryRecord(
      recordKey: recordKey,
      scope: scope,
      scopeId: scopeId,
      kind: kind,
      content: content,
      source: source,
      updatedAt: updatedAt.toInt(),
      status: status,
      before: json['before'] is String ? json['before']! as String : null,
      after: json['after'] is String ? json['after']! as String : null,
      reason: json['reason'] is String ? json['reason']! as String : null,
    );
  }

  static T? _enumByName<T extends Enum>(List<T> values, String name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

abstract final class AssistantDurableMemoryPolicy {
  /// Small enough for deterministic local retrieval and bounded storage.
  static const int maxRecordsPerScope = 64;

  /// Durable memory stores compact facts, never whole logs/transcripts.
  static const int maxContentChars = 800;
  static const int maxTransitionFieldChars = 300;
  static const int maxSourceChars = 64;
  static const int maxKeyChars = 160;
  static const int maxScopeIdChars = 160;
}
