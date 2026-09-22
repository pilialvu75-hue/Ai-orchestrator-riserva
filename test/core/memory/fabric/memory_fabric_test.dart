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

  test('cloud-only provider cannot accept device-only or secret records', () {
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
