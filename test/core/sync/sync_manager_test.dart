import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/sync/crdt/hlc.dart';
import 'package:ai_orchestrator/core/sync/sync_manager.dart';

class MockDatabaseHelper extends Mock implements DatabaseHelper {}

void main() {
  late MockDatabaseHelper mockDb;
  late SyncManager syncManager;

  setUp(() {
    mockDb = MockDatabaseHelper();
    syncManager = SyncManager(
      databaseHelper: mockDb,
      nodeId: 'test-node-id',
    );

    // Default stub: no existing changes.
    when(() => mockDb.getSyncChangesSince(any()))
        .thenAnswer((_) async => []);
    when(() => mockDb.insertSyncChange(any()))
        .thenAnswer((_) async {});
    when(() => mockDb.getMaxSyncHlc())
        .thenAnswer((_) async => null);
    when(() => mockDb.countSyncChanges())
        .thenAnswer((_) async => 0);
  });

  group('SyncManager – load', () {
    test('loads without error when no changes exist', () async {
      await expectLater(syncManager.load(), completes);
    });

    test('does not reload after first load', () async {
      await syncManager.load();
      await syncManager.load(); // second call should be a no-op
      verify(() => mockDb.getSyncChangesSince(any())).called(1);
    });
  });

  group('SyncManager – recordChange', () {
    test('persists a change to the database', () async {
      await syncManager.recordChange(
        collection: 'chat_history',
        key: 'msg-001',
        value: {'text': 'hello', 'role': 'user'},
      );
      verify(() => mockDb.insertSyncChange(any())).called(1);
    });

    test('returns a record with the correct collection and key', () async {
      final record = await syncManager.recordChange(
        collection: 'project_memory',
        key: 'proj-A',
        value: {'goal': 'Build offline AI'},
      );
      expect(record.collection, 'project_memory');
      expect(record.key, 'proj-A');
      expect(record.isTombstone, isFalse);
    });
  });

  group('SyncManager – recordDeletion', () {
    test('creates a tombstone record', () async {
      final record = await syncManager.recordDeletion(
        collection: 'chat_history',
        key: 'msg-999',
      );
      expect(record.isTombstone, isTrue);
      verify(() => mockDb.insertSyncChange(any())).called(1);
    });
  });

  group('SyncManager – exportChangesSince', () {
    test('returns empty list when no changes recorded', () async {
      final changes = await syncManager.exportChangesSince();
      expect(changes, isEmpty);
    });

    test('returns recorded changes as JSON maps', () async {
      await syncManager.recordChange(
        collection: 'chat_history',
        key: 'msg-1',
        value: {'text': 'hi'},
      );
      final changes = await syncManager.exportChangesSince(
        Hlc.zero('test-node-id').toString(),
      );
      expect(changes.length, 1);
      expect(changes.first['collection'], 'chat_history');
      expect(changes.first['key'], 'msg-1');
    });
  });

  group('SyncManager – applyRemoteChangeset', () {
    test('applies and persists incoming records', () async {
      final remoteRecord = {
        'id': 'remote-uuid-1',
        'collection': 'project_memory',
        'key': 'proj-remote',
        'value': '{"goal":"Remote goal"}',
        'hlc': '0000009999999999-000099-remote-node',
        'nodeId': 'remote-node',
      };
      final applied =
          await syncManager.applyRemoteChangeset([remoteRecord]);
      expect(applied, 1);
      verify(() => mockDb.insertSyncChange(any())).called(1);
    });

    test('does not apply an older remote record when local is newer', () async {
      // First, record a local change.
      await syncManager.recordChange(
        collection: 'project_memory',
        key: 'proj-X',
        value: {'goal': 'Local goal'},
      );
      // Capture the local HLC from the inserted record.
      final captured = verify(() => mockDb.insertSyncChange(captureAny()))
          .captured
          .last as Map<String, dynamic>;
      final localHlcStr = captured['hlc'] as String;

      // Reset call count.
      clearInteractions(mockDb);
      when(() => mockDb.insertSyncChange(any())).thenAnswer((_) async {});

      // Try to apply an older remote record.
      final olderHlc =
          Hlc.parse(localHlcStr).wallMs > 0
              ? '0000000000000001-000000-remote-node'
              : '0000000000000000-000000-remote-node';
      final applied = await syncManager.applyRemoteChangeset([
        {
          'id': 'remote-uuid-old',
          'collection': 'project_memory',
          'key': 'proj-X',
          'value': '{"goal":"Stale remote goal"}',
          'hlc': olderHlc,
          'nodeId': 'remote-node',
        }
      ]);
      expect(applied, 0);
      verifyNever(() => mockDb.insertSyncChange(any()));
    });
  });

  group('SyncManager – getRecord / getCollection', () {
    test('getRecord returns value after recording a change', () async {
      await syncManager.recordChange(
        collection: 'chat_history',
        key: 'msg-abc',
        value: {'text': 'test message'},
      );
      final value =
          await syncManager.getRecord('chat_history', 'msg-abc');
      expect(value, isNotNull);
      expect(value?['text'], 'test message');
    });

    test('getRecord returns null for non-existent key', () async {
      final value =
          await syncManager.getRecord('chat_history', 'no-such-key');
      expect(value, isNull);
    });

    test('getCollection returns all non-tombstone records', () async {
      await syncManager.recordChange(
          collection: 'col', key: 'a', value: {'n': 1});
      await syncManager.recordChange(
          collection: 'col', key: 'b', value: {'n': 2});
      await syncManager.recordDeletion(collection: 'col', key: 'a');
      final entries = await syncManager.getCollection('col');
      expect(entries.length, 1);
      expect(entries.first['n'], 2);
    });
  });

  group('SyncManager – maxHlc / changeCount', () {
    test('maxHlc delegates to database', () async {
      when(() => mockDb.getMaxSyncHlc())
          .thenAnswer((_) async => '0000001234567890-000001-test-node-id');
      final maxHlc = await syncManager.maxHlc();
      expect(maxHlc, isNotNull);
    });

    test('changeCount delegates to database', () async {
      when(() => mockDb.countSyncChanges()).thenAnswer((_) async => 5);
      expect(await syncManager.changeCount(), 5);
    });
  });
}
