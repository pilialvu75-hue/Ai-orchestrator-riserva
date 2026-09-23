import 'package:ai_orchestrator/core/memory/fabric/memory_fabric.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_provider.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('record wire contract and checksum match AIrLab V1', () {
    final record = MemoryFabricRecord.create(
      id: '00000000-0000-4000-8000-000000000001',
      namespace: 'airlab.project',
      type: MemoryFabricType.project,
      subject: 'project_state',
      content: 'Project p1',
      source: 'verified_test',
      structuredData: <String, Object?>{
        'z': 2,
        'a': <String, Object?>{'b': true, 'a': 'è'},
      },
      now: DateTime.utc(2026, 9, 22, 7, 0, 0, 123, 456),
      tags: const <String>['project', 'test'],
      projectId: 'p1',
    );

    expect(
      record.checksum,
      '0d3b933365509f35c88d5ae90e84704def1b4ab33f2e33f874f3bcf879e8b2e6',
    );
    expect(record.checksumValid, isTrue);
    expect(record.toJson()['type'], 'project');
    expect(record.toJson()['privacy_level'], 'project');

    final roundTrip = MemoryFabricRecord.fromJson(record.toJson());
    expect(roundTrip.checksum, record.checksum);
    expect(roundTrip.checksumValid, isTrue);
    expect(roundTrip.structuredData, record.structuredData);
  });

  test('write degrades from failed primary to secondary', () async {
    final primary = _MapProvider('primary', fail: true);
    final secondary = _MapProvider('secondary');
    final fabric = MemoryFabric(<MemoryFabricNode>[
      MemoryFabricNode(
        provider: primary,
        role: MemoryFabricNodeRole.primary,
      ),
      MemoryFabricNode(
        provider: secondary,
        role: MemoryFabricNodeRole.secondary,
      ),
    ]);

    final record = MemoryFabricRecord.create(
      namespace: 'test',
      type: MemoryFabricType.executionHistory,
      subject: 'checkpoint',
      content: 'safe to resume',
      source: 'test',
      projectId: 'p1',
    );
    final written = await fabric.write(record);

    expect(written.replicationState['primary'], 'failed');
    expect(written.replicationState['secondary'], 'synced');
    expect((await fabric.read(record.id))?.id, record.id);
  });

  test('cloud-only provider cannot accept device-only or secret records', () async {
    final cloud = _MapProvider(
      'cloud',
      location: 'cloud',
      allowedPrivacy: const <MemoryFabricPrivacyLevel>{
        MemoryFabricPrivacyLevel.public,
        MemoryFabricPrivacyLevel.project,
        MemoryFabricPrivacyLevel.private,
      },
    );
    final fabric = MemoryFabric(<MemoryFabricNode>[
      MemoryFabricNode(
        provider: cloud,
        role: MemoryFabricNodeRole.primary,
      ),
    ]);

    for (final privacy in <MemoryFabricPrivacyLevel>[
      MemoryFabricPrivacyLevel.deviceOnly,
      MemoryFabricPrivacyLevel.secret,
    ]) {
      final record = MemoryFabricRecord.create(
        namespace: 'private',
        type: MemoryFabricType.longTermFact,
        subject: 'local-only',
        content: 'must not leave device',
        source: 'test',
        privacyLevel: privacy,
      );
      await expectLater(
        fabric.write(record),
        throwsA(isA<MemoryFabricPolicyException>()),
      );
    }
  });

  test('read skips corrupted primary copy and recovers replica', () async {
    final primary = _MapProvider('primary');
    final secondary = _MapProvider('secondary');
    final fabric = MemoryFabric(<MemoryFabricNode>[
      MemoryFabricNode(
        provider: primary,
        role: MemoryFabricNodeRole.primary,
      ),
      MemoryFabricNode(
        provider: secondary,
        role: MemoryFabricNodeRole.secondary,
      ),
    ]);

    final record = MemoryFabricRecord.create(
      namespace: 'resilience',
      type: MemoryFabricType.failureSolution,
      subject: 'validated-fix',
      content: 'working copy',
      source: 'verified_test',
    );
    await fabric.write(record);

    primary.rows[record.id] = MemoryFabricRecord.fromJson(<String, Object?>{
      ...record.toJson(),
      'content': 'corrupted',
      'checksum': record.checksum,
    });

    final recovered = await fabric.read(record.id);
    expect(recovered, isNotNull);
    expect(recovered!.content, 'working copy');
  });

  test('replicate copies a valid record to another eligible node', () async {
    final local = _MapProvider('local');
    final nas = _MapProvider('nas', location: 'lan');
    final fabric = MemoryFabric(<MemoryFabricNode>[
      MemoryFabricNode(
        provider: local,
        role: MemoryFabricNodeRole.primary,
      ),
      MemoryFabricNode(
        provider: nas,
        role: MemoryFabricNodeRole.secondary,
      ),
    ]);

    final record = MemoryFabricRecord.create(
      namespace: 'knowledge',
      type: MemoryFabricType.knowledge,
      subject: 'shared',
      content: 'validated knowledge',
      source: 'verified_test',
    );
    local.rows[record.id] = record;

    final report = await fabric.replicate(
      record.id,
      sourceProviderId: 'local',
    );

    expect(report.succeeded, <String>['nas']);
    expect(nas.rows[record.id]?.checksum, record.checksum);
  });


  test('device-only write never leaves device even if cloud is misconfigured', () async {
    final cloud = _MapProvider(
      'cloud',
      location: 'cloud',
      allowedPrivacy: Set<MemoryFabricPrivacyLevel>.of(
        MemoryFabricPrivacyLevel.values,
      ),
    );
    final local = _MapProvider('local', location: 'device');
    final fabric = MemoryFabric(<MemoryFabricNode>[
      MemoryFabricNode(
        provider: cloud,
        role: MemoryFabricNodeRole.primary,
      ),
      MemoryFabricNode(
        provider: local,
        role: MemoryFabricNodeRole.secondary,
      ),
    ]);

    final record = MemoryFabricRecord.create(
      namespace: 'private',
      type: MemoryFabricType.longTermFact,
      subject: 'device-only',
      content: 'never replicate remotely',
      source: 'test',
      privacyLevel: MemoryFabricPrivacyLevel.deviceOnly,
    );

    final written = await fabric.write(record);

    expect(local.rows.containsKey(record.id), isTrue);
    expect(cloud.rows, isEmpty);
    expect(written.replicationState['local'], 'synced');
    expect(written.replicationState.containsKey('cloud'), isFalse);
  });

  test('read ignores forbidden remote copy and falls back to local', () async {
    final cloud = _MapProvider(
      'cloud',
      location: 'cloud',
      allowedPrivacy: Set<MemoryFabricPrivacyLevel>.of(
        MemoryFabricPrivacyLevel.values,
      ),
    );
    final local = _MapProvider('local', location: 'device');
    final fabric = MemoryFabric(<MemoryFabricNode>[
      MemoryFabricNode(
        provider: cloud,
        role: MemoryFabricNodeRole.primary,
      ),
      MemoryFabricNode(
        provider: local,
        role: MemoryFabricNodeRole.secondary,
      ),
    ]);

    final localRecord = MemoryFabricRecord.create(
      id: 'device-record',
      namespace: 'private',
      type: MemoryFabricType.longTermFact,
      subject: 'device-only',
      content: 'local truth',
      source: 'test',
      now: DateTime.utc(2026, 9, 22, 8),
      privacyLevel: MemoryFabricPrivacyLevel.deviceOnly,
    );
    final cloudRecord = localRecord.nextVersion(
      content: 'remote copy must be ignored',
      now: DateTime.utc(2026, 9, 22, 8, 1),
    );
    cloud.rows[localRecord.id] = cloudRecord;
    local.rows[localRecord.id] = localRecord;

    final recovered = await fabric.read(localRecord.id);

    expect(recovered, isNotNull);
    expect(recovered!.version, 1);
    expect(recovered.content, 'local truth');
  });

  test('secret defaults to device-only but trusted LAN requires opt-in', () async {
    final nas = _MapProvider(
      'nas',
      location: 'lan',
      allowedPrivacy: Set<MemoryFabricPrivacyLevel>.of(
        MemoryFabricPrivacyLevel.values,
      ),
    );
    final secret = MemoryFabricRecord.create(
      namespace: 'secrets',
      type: MemoryFabricType.longTermFact,
      subject: 'credential-reference',
      content: 'encrypted reference',
      source: 'test',
      privacyLevel: MemoryFabricPrivacyLevel.secret,
    );

    final defaultFabric = MemoryFabric(<MemoryFabricNode>[
      MemoryFabricNode(
        provider: nas,
        role: MemoryFabricNodeRole.primary,
      ),
    ]);
    await expectLater(
      defaultFabric.write(secret),
      throwsA(isA<MemoryFabricPolicyException>()),
    );
    expect(nas.rows, isEmpty);

    final trustedLanFabric = MemoryFabric(
      <MemoryFabricNode>[
        MemoryFabricNode(
          provider: nas,
          role: MemoryFabricNodeRole.primary,
        ),
      ],
      routingPolicy: const MemoryFabricRoutingPolicy(
        allowSecretOnLan: true,
      ),
    );
    await trustedLanFabric.write(secret);
    expect(nas.rows.containsKey(secret.id), isTrue);
  });

  test('private cloud routing can be disabled centrally', () async {
    final cloud = _MapProvider(
      'cloud',
      location: 'cloud',
      allowedPrivacy: const <MemoryFabricPrivacyLevel>{
        MemoryFabricPrivacyLevel.public,
        MemoryFabricPrivacyLevel.project,
        MemoryFabricPrivacyLevel.private,
      },
    );
    final record = MemoryFabricRecord.create(
      namespace: 'private',
      type: MemoryFabricType.userPreference,
      subject: 'preference',
      content: 'compact answers',
      source: 'test',
      privacyLevel: MemoryFabricPrivacyLevel.private,
    );

    final normal = MemoryFabric(<MemoryFabricNode>[
      MemoryFabricNode(
        provider: cloud,
        role: MemoryFabricNodeRole.primary,
      ),
    ]);
    await normal.write(record);
    expect(cloud.rows.containsKey(record.id), isTrue);

    cloud.rows.clear();
    final localOnlyPrivate = MemoryFabric(
      <MemoryFabricNode>[
        MemoryFabricNode(
          provider: cloud,
          role: MemoryFabricNodeRole.primary,
        ),
      ],
      routingPolicy: const MemoryFabricRoutingPolicy(
        allowPrivateOnCloud: false,
      ),
    );
    await expectLater(
      localOnlyPrivate.write(record),
      throwsA(isA<MemoryFabricPolicyException>()),
    );
    expect(cloud.rows, isEmpty);
  });

  test('replication policy cannot copy device-only record to cloud', () async {
    final local = _MapProvider('local', location: 'device');
    final cloud = _MapProvider(
      'cloud',
      location: 'cloud',
      allowedPrivacy: Set<MemoryFabricPrivacyLevel>.of(
        MemoryFabricPrivacyLevel.values,
      ),
    );
    final fabric = MemoryFabric(<MemoryFabricNode>[
      MemoryFabricNode(
        provider: local,
        role: MemoryFabricNodeRole.primary,
      ),
      MemoryFabricNode(
        provider: cloud,
        role: MemoryFabricNodeRole.secondary,
      ),
    ]);
    final record = MemoryFabricRecord.create(
      namespace: 'private',
      type: MemoryFabricType.longTermFact,
      subject: 'device-only',
      content: 'local',
      source: 'test',
      privacyLevel: MemoryFabricPrivacyLevel.deviceOnly,
    );
    local.rows[record.id] = record;

    final report = await fabric.replicate(
      record.id,
      sourceProviderId: 'local',
    );

    expect(report.attempted, isEmpty);
    expect(report.succeeded, isEmpty);
    expect(cloud.rows, isEmpty);
  });

}

final class _MapProvider implements MemoryFabricProvider {
  _MapProvider(
    String providerId, {
    this.fail = false,
    String location = 'device',
    Set<MemoryFabricPrivacyLevel>? allowedPrivacy,
  }) : descriptor = MemoryFabricProviderDescriptor(
          providerId: providerId,
          location: location,
          allowedPrivacy:
              allowedPrivacy ?? Set<MemoryFabricPrivacyLevel>.of(
                MemoryFabricPrivacyLevel.values,
              ),
        );

  @override
  final MemoryFabricProviderDescriptor descriptor;

  final bool fail;
  final Map<String, MemoryFabricRecord> rows = <String, MemoryFabricRecord>{};

  @override
  Future<MemoryFabricRecord> write(MemoryFabricRecord record) async {
    if (fail) throw StateError('node unavailable');
    rows[record.id] = record;
    return record;
  }

  @override
  Future<MemoryFabricRecord?> read(String recordId) async {
    if (fail) throw StateError('node unavailable');
    return rows[recordId];
  }

  @override
  Future<List<MemoryFabricRecord>> search(MemoryFabricQuery query) async {
    if (fail) throw StateError('node unavailable');
    return rows.values
        .where(
          (record) =>
              query.projectId == null || record.projectId == query.projectId,
        )
        .take(query.limit)
        .toList(growable: false);
  }

  @override
  Future<MemoryFabricSyncReport> sync() async {
    if (fail) throw StateError('node unavailable');
    return MemoryFabricSyncReport(providerId: descriptor.providerId, ok: true);
  }

  @override
  Future<MemoryFabricHealth> health() async => MemoryFabricHealth(
        providerId: descriptor.providerId,
        status: fail
            ? MemoryFabricHealthStatus.unavailable
            : MemoryFabricHealthStatus.healthy,
        readable: !fail,
        writable: !fail,
        checkedAt: DateTime.now().toUtc(),
      );
}
