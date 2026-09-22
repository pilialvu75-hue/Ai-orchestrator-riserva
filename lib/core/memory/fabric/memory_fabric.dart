import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_provider.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_record.dart';

final class MemoryFabricPolicyException implements Exception {
  const MemoryFabricPolicyException(this.message);

  final String message;

  @override
  String toString() => 'MemoryFabricPolicyException: $message';
}

final class MemoryFabricRoutingPolicy {
  const MemoryFabricRoutingPolicy({
    this.allowPrivateOnCloud = true,
    this.allowSecretOnLan = false,
    this.allowSecretOnCloud = false,
  });

  /// PRIVATE remains cloud-capable by default because shared authenticated
  /// backends are part of V1. It can be disabled without changing providers.
  final bool allowPrivateOnCloud;

  /// SECRET is device-only by default. Future trusted/encrypted LAN or cloud
  /// nodes require an explicit opt-in here; adapters cannot grant it alone.
  final bool allowSecretOnLan;
  final bool allowSecretOnCloud;

  bool allows({
    required MemoryFabricPrivacyLevel privacy,
    required String location,
  }) {
    return switch (privacy) {
      MemoryFabricPrivacyLevel.public => true,
      MemoryFabricPrivacyLevel.project => true,
      MemoryFabricPrivacyLevel.private =>
        location != 'cloud' || allowPrivateOnCloud,
      MemoryFabricPrivacyLevel.deviceOnly => location == 'device',
      MemoryFabricPrivacyLevel.secret => switch (location) {
          'device' => true,
          'lan' => allowSecretOnLan,
          'cloud' => allowSecretOnCloud,
          _ => false,
        },
    };
  }

  bool allowsNode(
    MemoryFabricNode node,
    MemoryFabricPrivacyLevel privacy,
  ) {
    return node.accepts(privacy) &&
        allows(
          privacy: privacy,
          location: node.provider.descriptor.location,
        );
  }
}

final class MemoryFabricNode {
  MemoryFabricNode({
    required this.provider,
    required this.role,
    this.priority = 100,
    Set<MemoryFabricPrivacyLevel>? allowedPrivacy,
  }) : allowedPrivacy = allowedPrivacy == null
            ? null
            : Set<MemoryFabricPrivacyLevel>.unmodifiable(allowedPrivacy);

  final MemoryFabricProvider provider;
  final MemoryFabricNodeRole role;
  final int priority;
  final Set<MemoryFabricPrivacyLevel>? allowedPrivacy;

  bool accepts(MemoryFabricPrivacyLevel privacy) {
    final nodeLevels = allowedPrivacy;
    if (nodeLevels != null && !nodeLevels.contains(privacy)) {
      return false;
    }
    return provider.descriptor.allowedPrivacy.contains(privacy);
  }
}

/// Provider-neutral routing facade.
///
/// It is intentionally not registered in application DI yet. Open Assistant
/// memory PRs own their current wiring; this class is the shared contract that
/// future local/Supabase/NAS adapters can converge on without duplicating them.
final class MemoryFabric {
  MemoryFabric(
    Iterable<MemoryFabricNode> nodes, {
    MemoryFabricRoutingPolicy routingPolicy =
        const MemoryFabricRoutingPolicy(),
  })  : _routingPolicy = routingPolicy,
        _nodes = List<MemoryFabricNode>.of(nodes)
          ..sort((left, right) {
            final role = _roleRank(left.role).compareTo(_roleRank(right.role));
            if (role != 0) return role;
            final priority = left.priority.compareTo(right.priority);
            if (priority != 0) return priority;
            return left.provider.descriptor.providerId
                .compareTo(right.provider.descriptor.providerId);
          }) {
    if (_nodes.isEmpty) {
      throw ArgumentError('MemoryFabric requires at least one node');
    }
  }

  final MemoryFabricRoutingPolicy _routingPolicy;
  final List<MemoryFabricNode> _nodes;

  Future<MemoryFabricRecord> write(MemoryFabricRecord record) async {
    final candidates = _nodes
        .where(
          (node) =>
              node.role != MemoryFabricNodeRole.readOnly &&
              _routingPolicy.allowsNode(node, record.privacyLevel),
        )
        .toList(growable: false);

    if (candidates.isEmpty) {
      throw MemoryFabricPolicyException(
        'No writable memory node accepts '
        'privacy=${record.privacyLevel.wireName}',
      );
    }

    final succeeded = <String>{};
    final failed = <String, String>{};

    for (final node in candidates) {
      final providerId = node.provider.descriptor.providerId;
      try {
        await node.provider.write(record);
        succeeded.add(providerId);
      } on Object catch (error) {
        failed[providerId] = error.toString();
      }
    }

    if (succeeded.isEmpty) {
      final details = failed.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join(', ');
      throw StateError('All eligible memory nodes rejected the write: $details');
    }

    final state = <String, String>{
      for (final node in candidates)
        node.provider.descriptor.providerId:
            succeeded.contains(node.provider.descriptor.providerId)
                ? 'synced'
                : 'failed',
    };
    final finalRecord = record.withReplicationState(state);

    // Best-effort update of replication metadata. A metadata refresh failure
    // cannot invalidate a durable copy that has already been accepted.
    for (final node in candidates) {
      if (!succeeded.contains(node.provider.descriptor.providerId)) continue;
      try {
        await node.provider.write(finalRecord);
      } on Object {
        // Intentionally degraded.
      }
    }

    return finalRecord;
  }

  Future<MemoryFabricRecord?> read(String recordId) async {
    for (final node in _nodes) {
      try {
        final record = await node.provider.read(recordId);
        if (record == null ||
            record.isExpired() ||
            !record.checksumValid ||
            !_routingPolicy.allowsNode(node, record.privacyLevel)) {
          continue;
        }
        return record;
      } on Object {
        continue;
      }
    }
    return null;
  }

  Future<List<MemoryFabricRecord>> search(MemoryFabricQuery query) async {
    final winners = <String, MemoryFabricRecord>{};

    for (final node in _nodes) {
      List<MemoryFabricRecord> records;
      try {
        records = await node.provider.search(query);
      } on Object {
        continue;
      }

      for (final record in records) {
        if ((!query.includeExpired && record.isExpired()) ||
            !record.checksumValid ||
            !_routingPolicy.allowsNode(node, record.privacyLevel)) {
          continue;
        }
        final existing = winners[record.id];
        if (existing == null || _isNewer(record, existing)) {
          winners[record.id] = record;
        }
      }
    }

    final result = winners.values.toList()
      ..sort((left, right) {
        final timestamp = right.updatedAt.compareTo(left.updatedAt);
        if (timestamp != 0) return timestamp;
        return right.version.compareTo(left.version);
      });

    return List<MemoryFabricRecord>.unmodifiable(
      result.take(query.limit),
    );
  }

  Future<List<MemoryFabricSyncReport>> sync() async {
    final reports = <MemoryFabricSyncReport>[];
    for (final node in _nodes) {
      try {
        reports.add(await node.provider.sync());
      } on Object catch (error) {
        reports.add(
          MemoryFabricSyncReport(
            providerId: node.provider.descriptor.providerId,
            ok: false,
            details: <String, Object?>{'error': error.toString()},
          ),
        );
      }
    }
    return List<MemoryFabricSyncReport>.unmodifiable(reports);
  }

  Future<List<MemoryFabricHealth>> health() async {
    final results = <MemoryFabricHealth>[];
    for (final node in _nodes) {
      try {
        results.add(await node.provider.health());
      } on Object catch (error) {
        results.add(
          MemoryFabricHealth(
            providerId: node.provider.descriptor.providerId,
            status: MemoryFabricHealthStatus.unavailable,
            readable: false,
            writable: false,
            checkedAt: DateTime.now().toUtc(),
            details: <String, Object?>{'error': error.toString()},
          ),
        );
      }
    }
    return List<MemoryFabricHealth>.unmodifiable(results);
  }

  Future<MemoryFabricReplicationReport> replicate(
    String recordId, {
    String? sourceProviderId,
  }) async {
    MemoryFabricRecord? source;
    String? resolvedSourceProviderId;

    for (final node in _nodes) {
      final providerId = node.provider.descriptor.providerId;
      if (sourceProviderId != null && providerId != sourceProviderId) {
        continue;
      }
      try {
        final candidate = await node.provider.read(recordId);
        if (candidate != null &&
            candidate.checksumValid &&
            _routingPolicy.allowsNode(node, candidate.privacyLevel)) {
          source = candidate;
          resolvedSourceProviderId = providerId;
          break;
        }
      } on Object {
        continue;
      }
    }

    if (source == null) {
      return MemoryFabricReplicationReport(
        recordId: recordId,
        attempted: const <String>[],
        succeeded: const <String>[],
        failed: const <String, String>{
          'source': 'record not found on a readable node',
        },
      );
    }

    final attempted = <String>[];
    final succeeded = <String>[];
    final failed = <String, String>{};

    for (final node in _nodes) {
      final providerId = node.provider.descriptor.providerId;
      if (providerId == resolvedSourceProviderId ||
          node.role == MemoryFabricNodeRole.readOnly ||
          !_routingPolicy.allowsNode(node, source.privacyLevel)) {
        continue;
      }

      attempted.add(providerId);
      try {
        await node.provider.write(source);
        succeeded.add(providerId);
      } on Object catch (error) {
        failed[providerId] = error.toString();
      }
    }

    return MemoryFabricReplicationReport(
      recordId: recordId,
      attempted: List<String>.unmodifiable(attempted),
      succeeded: List<String>.unmodifiable(succeeded),
      failed: Map<String, String>.unmodifiable(failed),
    );
  }
}

bool _isNewer(MemoryFabricRecord candidate, MemoryFabricRecord existing) {
  if (candidate.version != existing.version) {
    return candidate.version > existing.version;
  }
  return candidate.updatedAt.isAfter(existing.updatedAt);
}

int _roleRank(MemoryFabricNodeRole role) => switch (role) {
      MemoryFabricNodeRole.primary => 0,
      MemoryFabricNodeRole.secondary => 1,
      MemoryFabricNodeRole.readOnly => 2,
      MemoryFabricNodeRole.offlineCache => 3,
    };
