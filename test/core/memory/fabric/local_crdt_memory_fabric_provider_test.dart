import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/memory/fabric/local_crdt_memory_fabric_provider.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_record.dart';
import 'package:ai_orchestrator/core/sync/sync_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

final class _MockDatabaseHelper extends Mock implements DatabaseHelper {}

void main() {
  late _MockDatabaseHelper database;
  late List<Map<String, dynamic>> rows;

  setUp(() {
    database = _MockDatabaseHelper();
    rows = <Map<String, dynamic>>[];

    when(() => database.getSyncChangesSince(any())).thenAnswer(
      (_) async => rows
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false),
    );
    when(() => database.insertSyncChange(any())).thenAnswer((invocation) async {
      final raw = invocation.positionalArguments.first;
      rows.add(Map<String, dynamic>.from(raw as Map));
    });
    when(() => database.getMaxSyncHlc()).thenAnswer(
      (_) async => rows.isEmpty ? null : rows.last['hlc']?.toString(),
    );
    when(() => database.countSyncChanges()).thenAnswer(
      (_) async => rows.length,
    );
  });

  LocalCrdtMemoryFabricProvider provider(String nodeId) =>
      LocalCrdtMemoryFabricProvider(
        syncManager: SyncManager(
          databaseHelper: database,
          nodeId: nodeId,
        ),
      );

  test('persists canonical record through existing CRDT journal', () async {
    final firstProcess = provider('device-a');
    final record = MemoryFabricRecord.create(
      id: 'memory-1',
      namespace: 'airlab.project',
      type: MemoryFabricType.project,
      subject: 'project_state',
      content: 'blocked',
      source: 'cantiere',
      projectId: 'project-1',
      structuredData: const <String, Object?>{
        'next_step': 'repair build',
      },
    );

    await firstProcess.write(record);
    expect(rows, hasLength(1));

    // Recreate SyncManager + provider: only the persisted CRDT rows survive.
    final secondProcess = provider('device-a');
    final recovered = await secondProcess.read(record.id);

    expect(recovered, isNotNull);
    expect(recovered!.checksum, record.checksum);
    expect(recovered.projectId, 'project-1');
    expect(recovered.structuredData['next_step'], 'repair build');
  });

  test('preserves same-version replication metadata updates', () async {
    final local = provider('device-a');
    final record = MemoryFabricRecord.create(
      id: 'memory-2',
      namespace: 'knowledge',
      type: MemoryFabricType.knowledge,
      subject: 'fact',
      content: 'validated',
      source: 'verified_test',
    );
    await local.write(record);

    final replicated = record.withReplicationState(
      const <String, String>{'local_crdt': 'synced'},
    );
    await local.write(replicated);

    final recovered = await local.read(record.id);
    expect(recovered?.version, 1);
    expect(recovered?.checksum, record.checksum);
    expect(recovered?.replicationState['local_crdt'], 'synced');
  });

  test('rejects logical version regression and same-version conflict', () async {
    final local = provider('device-a');
    final versionOne = MemoryFabricRecord.create(
      id: 'memory-3',
      namespace: 'project',
      type: MemoryFabricType.project,
      subject: 'state',
      content: 'running',
      source: 'cantiere',
    );
    final versionTwo = versionOne.nextVersion(
      content: 'blocked',
      now: versionOne.updatedAt.add(const Duration(seconds: 1)),
    );

    await local.write(versionTwo);

    await expectLater(
      local.write(versionOne),
      throwsA(isA<StateError>()),
    );

    final conflict = MemoryFabricRecord.fromJson(<String, Object?>{
      ...versionTwo.toJson(),
      'content': 'different payload',
      'checksum': 'different-checksum',
    });
    await expectLater(
      local.write(conflict),
      throwsA(isA<StateError>()),
    );
  });

  test('search supports scope metadata text tags and time filters', () async {
    final local = provider('device-a');
    final base = DateTime.utc(2026, 9, 22, 8);

    await local.write(
      MemoryFabricRecord.create(
        id: 'memory-4',
        namespace: 'research',
        type: MemoryFabricType.researchKnowledge,
        subject: 'Vulkan backend',
        content: 'Validated acceleration evidence',
        source: 'researcher',
        now: base,
        projectId: 'project-7',
        tags: const <String>['gpu', 'validated'],
      ),
    );
    await local.write(
      MemoryFabricRecord.create(
        id: 'memory-5',
        namespace: 'research',
        type: MemoryFabricType.researchKnowledge,
        subject: 'CPU fallback',
        content: 'Fallback evidence',
        source: 'researcher',
        now: base.add(const Duration(minutes: 1)),
        projectId: 'project-8',
        tags: const <String>['cpu'],
      ),
    );

    final results = await local.search(
      MemoryFabricQuery(
        namespace: 'research',
        types: const <MemoryFabricType>[
          MemoryFabricType.researchKnowledge,
        ],
        text: 'acceleration',
        tags: const <String>['validated'],
        projectId: 'project-7',
        updatedAfter: base.subtract(const Duration(seconds: 1)),
        updatedBefore: base.add(const Duration(seconds: 1)),
      ),
    );

    expect(results.map((record) => record.id), <String>['memory-4']);
  });

  test('health and sync expose existing CRDT state without network', () async {
    final local = provider('device-a');
    await local.write(
      MemoryFabricRecord.create(
        id: 'memory-6',
        namespace: 'health',
        type: MemoryFabricType.providerResourceState,
        subject: 'local',
        content: 'ready',
        source: 'runtime',
      ),
    );

    final health = await local.health();
    final sync = await local.sync();

    expect(health.status, MemoryFabricHealthStatus.healthy);
    expect(health.readable, isTrue);
    expect(health.writable, isTrue);
    expect(health.details['node_id'], 'device-a');
    expect(sync.ok, isTrue);
    expect(sync.details['mode'], 'local_crdt_ready');
    expect(sync.details['change_count'], 1);
  });
}
