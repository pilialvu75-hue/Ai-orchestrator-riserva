import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

/// Provider-neutral memory classes shared with AIrLab Memory Fabric V1.
enum MemoryFabricType {
  conversation,
  project,
  userPreference,
  knowledge,
  libraryKnowledge,
  researchKnowledge,
  executionHistory,
  failureSolution,
  artifactMetadata,
  providerResourceState,
  decisionLog,
  episodic,
  longTermFact,
}

enum MemoryFabricPrivacyLevel { public, project, private, deviceOnly, secret }

enum MemoryFabricNodeRole { primary, secondary, readOnly, offlineCache }

enum MemoryFabricHealthStatus { healthy, degraded, unavailable }

extension MemoryFabricTypeWire on MemoryFabricType {
  String get wireName => switch (this) {
        MemoryFabricType.conversation => 'conversation',
        MemoryFabricType.project => 'project',
        MemoryFabricType.userPreference => 'user_preference',
        MemoryFabricType.knowledge => 'knowledge',
        MemoryFabricType.libraryKnowledge => 'library_knowledge',
        MemoryFabricType.researchKnowledge => 'research_knowledge',
        MemoryFabricType.executionHistory => 'execution_history',
        MemoryFabricType.failureSolution => 'failure_solution',
        MemoryFabricType.artifactMetadata => 'artifact_metadata',
        MemoryFabricType.providerResourceState => 'provider_resource_state',
        MemoryFabricType.decisionLog => 'decision_log',
        MemoryFabricType.episodic => 'episodic',
        MemoryFabricType.longTermFact => 'long_term_fact',
      };

  static MemoryFabricType parse(String value) {
    for (final item in MemoryFabricType.values) {
      if (item.wireName == value) return item;
    }
    throw FormatException('Unknown memory type: $value');
  }
}

extension MemoryFabricPrivacyLevelWire on MemoryFabricPrivacyLevel {
  String get wireName => switch (this) {
        MemoryFabricPrivacyLevel.public => 'public',
        MemoryFabricPrivacyLevel.project => 'project',
        MemoryFabricPrivacyLevel.private => 'private',
        MemoryFabricPrivacyLevel.deviceOnly => 'device_only',
        MemoryFabricPrivacyLevel.secret => 'secret',
      };

  static MemoryFabricPrivacyLevel parse(String value) {
    for (final item in MemoryFabricPrivacyLevel.values) {
      if (item.wireName == value) return item;
    }
    throw FormatException('Unknown memory privacy level: $value');
  }
}

extension MemoryFabricNodeRoleWire on MemoryFabricNodeRole {
  String get wireName => switch (this) {
        MemoryFabricNodeRole.primary => 'primary',
        MemoryFabricNodeRole.secondary => 'secondary',
        MemoryFabricNodeRole.readOnly => 'read_only',
        MemoryFabricNodeRole.offlineCache => 'offline_cache',
      };
}

/// Canonical record exchanged by AI-Orchestrator and AIrLab.
///
/// [replicationState] is excluded from the checksum so replication metadata can
/// change idempotently without changing the logical record version.
final class MemoryFabricRecord {
  MemoryFabricRecord({
    required this.id,
    required this.namespace,
    required this.type,
    required this.subject,
    required this.content,
    required Map<String, Object?> structuredData,
    required this.source,
    required this.confidence,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
    required this.ttlSeconds,
    required Map<String, String> replicationState,
    required this.privacyLevel,
    required this.checksum,
    required List<String> tags,
    this.projectId,
    this.userId,
    this.agentId,
    this.conversationId,
  })  : structuredData = Map<String, Object?>.unmodifiable(structuredData),
        replicationState = Map<String, String>.unmodifiable(replicationState),
        tags = List<String>.unmodifiable(tags) {
    _validate();
  }

  final String id;
  final String namespace;
  final MemoryFabricType type;
  final String subject;
  final String content;
  final Map<String, Object?> structuredData;
  final String source;
  final double confidence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;
  final int? ttlSeconds;
  final Map<String, String> replicationState;
  final MemoryFabricPrivacyLevel privacyLevel;
  final String checksum;
  final List<String> tags;
  final String? projectId;
  final String? userId;
  final String? agentId;
  final String? conversationId;

  factory MemoryFabricRecord.create({
    String? id,
    required String namespace,
    required MemoryFabricType type,
    required String subject,
    required String content,
    required String source,
    Map<String, Object?> structuredData = const <String, Object?>{},
    double confidence = 1.0,
    DateTime? now,
    int? ttlSeconds,
    MemoryFabricPrivacyLevel privacyLevel = MemoryFabricPrivacyLevel.project,
    List<String> tags = const <String>[],
    String? projectId,
    String? userId,
    String? agentId,
    String? conversationId,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    final record = MemoryFabricRecord(
      id: _required(id ?? const Uuid().v4(), 'id'),
      namespace: _required(namespace, 'namespace'),
      type: type,
      subject: _required(subject, 'subject'),
      content: content,
      structuredData: Map<String, Object?>.from(structuredData),
      source: _required(source, 'source'),
      confidence: confidence,
      createdAt: timestamp,
      updatedAt: timestamp,
      version: 1,
      ttlSeconds: ttlSeconds,
      replicationState: const <String, String>{},
      privacyLevel: privacyLevel,
      checksum: '',
      tags: _normalizedTags(tags),
      projectId: _optional(projectId),
      userId: _optional(userId),
      agentId: _optional(agentId),
      conversationId: _optional(conversationId),
    );
    return record._withChecksum(record.computeChecksum());
  }

  MemoryFabricRecord nextVersion({
    String? content,
    Map<String, Object?>? structuredData,
    String? source,
    double? confidence,
    Map<String, String>? replicationState,
    List<String>? tags,
    DateTime? now,
  }) {
    final next = MemoryFabricRecord(
      id: id,
      namespace: namespace,
      type: type,
      subject: subject,
      content: content ?? this.content,
      structuredData:
          Map<String, Object?>.from(structuredData ?? this.structuredData),
      source: source == null ? this.source : _required(source, 'source'),
      confidence: confidence ?? this.confidence,
      createdAt: createdAt,
      updatedAt: (now ?? DateTime.now()).toUtc(),
      version: version + 1,
      ttlSeconds: ttlSeconds,
      replicationState:
          Map<String, String>.from(replicationState ?? this.replicationState),
      privacyLevel: privacyLevel,
      checksum: '',
      tags: _normalizedTags(tags ?? this.tags),
      projectId: projectId,
      userId: userId,
      agentId: agentId,
      conversationId: conversationId,
    );
    return next._withChecksum(next.computeChecksum());
  }

  MemoryFabricRecord withReplicationState(Map<String, String> value) {
    return MemoryFabricRecord(
      id: id,
      namespace: namespace,
      type: type,
      subject: subject,
      content: content,
      structuredData: structuredData,
      source: source,
      confidence: confidence,
      createdAt: createdAt,
      updatedAt: updatedAt,
      version: version,
      ttlSeconds: ttlSeconds,
      replicationState: value,
      privacyLevel: privacyLevel,
      checksum: checksum,
      tags: tags,
      projectId: projectId,
      userId: userId,
      agentId: agentId,
      conversationId: conversationId,
    );
  }

  bool isExpired([DateTime? now]) {
    final ttl = ttlSeconds;
    if (ttl == null) return false;
    return !(now ?? DateTime.now())
        .toUtc()
        .isBefore(createdAt.toUtc().add(Duration(seconds: ttl)));
  }

  bool get checksumValid =>
      checksum.isNotEmpty && checksum == computeChecksum();

  String computeChecksum() {
    final canonical = _canonicalJson(<String, Object?>{
      'id': id,
      'namespace': namespace,
      'type': type.wireName,
      'subject': subject,
      'content': content,
      'structured_data': structuredData,
      'source': source,
      'confidence': confidence,
      'created_at': _isoUtc(createdAt),
      'updated_at': _isoUtc(updatedAt),
      'version': version,
      'ttl': ttlSeconds,
      'privacy_level': privacyLevel.wireName,
      'tags': tags,
      'project_id': projectId,
      'user_id': userId,
      'agent_id': agentId,
      'conversation_id': conversationId,
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'namespace': namespace,
        'type': type.wireName,
        'subject': subject,
        'content': content,
        'structured_data': structuredData,
        'source': source,
        'confidence': confidence,
        'created_at': _isoUtc(createdAt),
        'updated_at': _isoUtc(updatedAt),
        'version': version,
        'ttl': ttlSeconds,
        'replication_state': replicationState,
        'privacy_level': privacyLevel.wireName,
        'checksum': checksum,
        'tags': tags,
        'project_id': projectId,
        'user_id': userId,
        'agent_id': agentId,
        'conversation_id': conversationId,
      };

  factory MemoryFabricRecord.fromJson(Map<String, Object?> json) {
    final replicationState = <String, String>{};
    final rawReplicationState = json['replication_state'];
    if (rawReplicationState is Map) {
      for (final entry in rawReplicationState.entries) {
        if (entry.key is String && entry.value is String) {
          replicationState[entry.key as String] = entry.value as String;
        }
      }
    }
    final rawTags = json['tags'];
    return MemoryFabricRecord(
      id: _required(json['id']?.toString() ?? '', 'id'),
      namespace: _required(json['namespace']?.toString() ?? '', 'namespace'),
      type: MemoryFabricTypeWire.parse(json['type']?.toString() ?? ''),
      subject: _required(json['subject']?.toString() ?? '', 'subject'),
      content: json['content']?.toString() ?? '',
      structuredData: _objectMap(json['structured_data']),
      source: _required(json['source']?.toString() ?? '', 'source'),
      confidence: _double(json['confidence'], fallback: 1.0),
      createdAt: _date(json['created_at'], 'created_at'),
      updatedAt: _date(json['updated_at'], 'updated_at'),
      version: _integer(json['version'], fallback: 1),
      ttlSeconds:
          json['ttl'] == null ? null : _integer(json['ttl'], fallback: -1),
      replicationState: replicationState,
      privacyLevel: MemoryFabricPrivacyLevelWire.parse(
        json['privacy_level']?.toString() ?? 'project',
      ),
      checksum: json['checksum']?.toString() ?? '',
      tags: rawTags is List
          ? rawTags.whereType<String>().toList(growable: false)
          : const <String>[],
      projectId: _optional(json['project_id']?.toString()),
      userId: _optional(json['user_id']?.toString()),
      agentId: _optional(json['agent_id']?.toString()),
      conversationId: _optional(json['conversation_id']?.toString()),
    );
  }

  MemoryFabricRecord _withChecksum(String value) => MemoryFabricRecord(
        id: id,
        namespace: namespace,
        type: type,
        subject: subject,
        content: content,
        structuredData: structuredData,
        source: source,
        confidence: confidence,
        createdAt: createdAt,
        updatedAt: updatedAt,
        version: version,
        ttlSeconds: ttlSeconds,
        replicationState: replicationState,
        privacyLevel: privacyLevel,
        checksum: value,
        tags: tags,
        projectId: projectId,
        userId: userId,
        agentId: agentId,
        conversationId: conversationId,
      );

  void _validate() {
    _required(id, 'id');
    _required(namespace, 'namespace');
    _required(subject, 'subject');
    _required(source, 'source');
    if (confidence < 0 || confidence > 1) {
      throw ArgumentError.value(
        confidence,
        'confidence',
        'must be between 0 and 1',
      );
    }
    if (version < 1) {
      throw ArgumentError.value(version, 'version', 'must be >= 1');
    }
    if (ttlSeconds != null && ttlSeconds! < 0) {
      throw ArgumentError.value(ttlSeconds, 'ttlSeconds', 'must be >= 0');
    }
    if (updatedAt.toUtc().isBefore(createdAt.toUtc())) {
      throw ArgumentError('updatedAt cannot be before createdAt');
    }
  }
}

final class MemoryFabricQuery {
  MemoryFabricQuery({
    this.namespace,
    List<MemoryFabricType> types = const <MemoryFabricType>[],
    this.text,
    this.subject,
    List<String> tags = const <String>[],
    this.projectId,
    this.userId,
    this.agentId,
    this.conversationId,
    this.updatedAfter,
    this.updatedBefore,
    this.includeExpired = false,
    this.limit = 50,
  })  : types = List<MemoryFabricType>.unmodifiable(types),
        tags = List<String>.unmodifiable(tags) {
    if (limit < 1 || limit > 500) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 500');
    }
  }

  final String? namespace;
  final List<MemoryFabricType> types;
  final String? text;
  final String? subject;
  final List<String> tags;
  final String? projectId;
  final String? userId;
  final String? agentId;
  final String? conversationId;
  final DateTime? updatedAfter;
  final DateTime? updatedBefore;
  final bool includeExpired;
  final int limit;
}

final class MemoryFabricHealth {
  const MemoryFabricHealth({
    required this.providerId,
    required this.status,
    required this.readable,
    required this.writable,
    required this.checkedAt,
    this.details = const <String, Object?>{},
  });

  final String providerId;
  final MemoryFabricHealthStatus status;
  final bool readable;
  final bool writable;
  final DateTime checkedAt;
  final Map<String, Object?> details;
}

final class MemoryFabricSyncReport {
  const MemoryFabricSyncReport({
    required this.providerId,
    required this.ok,
    this.pulled = 0,
    this.pushed = 0,
    this.conflicts = 0,
    this.details = const <String, Object?>{},
  });

  final String providerId;
  final bool ok;
  final int pulled;
  final int pushed;
  final int conflicts;
  final Map<String, Object?> details;
}

final class MemoryFabricReplicationReport {
  const MemoryFabricReplicationReport({
    required this.recordId,
    required this.attempted,
    required this.succeeded,
    required this.failed,
  });

  final String recordId;
  final List<String> attempted;
  final List<String> succeeded;
  final Map<String, String> failed;
}

String _canonicalJson(Object? value) {
  Object? normalize(Object? item) {
    if (item is Map) {
      final pairs = item.entries
          .map((entry) => MapEntry(entry.key.toString(), entry.value))
          .toList()
        ..sort((left, right) => left.key.compareTo(right.key));
      return <String, Object?>{
        for (final pair in pairs) pair.key: normalize(pair.value),
      };
    }
    if (item is Iterable) {
      return item.map(normalize).toList(growable: false);
    }
    return item;
  }

  return jsonEncode(normalize(value));
}

String _isoUtc(DateTime value) {
  final utc = value.toUtc();
  final year = utc.year.toString().padLeft(4, '0');
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  final hour = utc.hour.toString().padLeft(2, '0');
  final minute = utc.minute.toString().padLeft(2, '0');
  final second = utc.second.toString().padLeft(2, '0');
  final micros = utc.millisecond * 1000 + utc.microsecond;
  final fraction =
      micros == 0 ? '' : '.${micros.toString().padLeft(6, '0')}';
  return '$year-$month-${day}T$hour:$minute:$second${fraction}Z';
}

String _required(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'is required');
  }
  return normalized;
}

String? _optional(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

List<String> _normalizedTags(Iterable<String> values) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    final normalized = value.trim();
    if (normalized.isNotEmpty && seen.add(normalized)) {
      result.add(normalized);
    }
  }
  return result;
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

DateTime _date(Object? value, String name) {
  final parsed = DateTime.tryParse(value?.toString() ?? '');
  if (parsed == null) throw FormatException('Invalid $name');
  return parsed.toUtc();
}

int _integer(Object? value, {required int fallback}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _double(Object? value, {required double fallback}) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}
