import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/features/chat_archive/data/chat_archive_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ChatArchiveCatalog catalog;

  const digest = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  ChatArchivePointer pointer({
    String archiveId = 'snapshot-1',
    String device = 'device-a',
    String session = 'default',
    String storage = 'future-provider',
    String key = 'conversation/snapshot-1.enc',
    String sha = digest,
    int created = 100,
    int? verifiedAt,
  }) =>
      ChatArchivePointer(
        archiveId: archiveId,
        originDeviceId: device,
        sourceSessionId: session,
        storageProviderId: storage,
        objectKey: key,
        ciphertextSha256: sha,
        ciphertextBytes: 120,
        messageCount: 5,
        indexedAtMs: created,
        remoteVerifiedAtMs: verifiedAt,
      );

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    // A representative v6 conversation. The additive v7 tables must never
    // rewrite these existing messages or the session's pinned state.
    await db.execute('''
      CREATE TABLE chat_sessions (
        id TEXT PRIMARY KEY, created_at INTEGER NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE chat_history (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
        role TEXT NOT NULL, content TEXT NOT NULL,
        timestamp INTEGER NOT NULL
      )
    ''');
    await db.insert('chat_sessions', <String, Object>{
      'id': 'default',
      'created_at': 10,
      'pinned': 1,
    });
    await db.insert('chat_history', <String, Object>{
      'id': 'msg-1',
      'session_id': 'default',
      'role': 'user',
      'content': 'Non modificare questa conversazione',
      'timestamp': 20,
    });
    await DatabaseHelper.createChatArchiveCatalogTables(db);
    catalog = ChatArchiveCatalog.forTesting(db);
  });

  tearDown(() async => db.close());

  test('database schema v7 is additive and does not erase existing chats',
      () async {
    expect(AppConstants.databaseVersion, 7);
    await DatabaseHelper.createChatArchiveCatalogTables(db);
    final sessions = await db.query('chat_sessions');
    final history = await db.query('chat_history');
    expect(sessions, hasLength(1));
    expect(sessions.single['pinned'], 1);
    expect(history, hasLength(1));
    expect(history.single['content'], 'Non modificare questa conversazione');
    expect(await db.query(AppConstants.tableChatArchiveCatalog), isEmpty);
    expect(await db.query(AppConstants.tableChatArchiveMemoryLinks), isEmpty);
  });

  test('pending pointers can be found without loading archived payloads',
      () async {
    final expected = pointer();
    await catalog.addPendingPointer(expected);
    final found = await catalog.findPointer('snapshot-1');
    expect(found, isNotNull);
    expect(found!.isRemoteVerified, isFalse);
    expect(found.storageProviderId, 'future-provider');
    expect(found.ciphertextSha256, digest);
    expect((await catalog.findByOrigin(
      originDeviceId: 'device-a',
      sessionId: 'default',
    )).single.archiveId, 'snapshot-1');
    expect((await db.query('chat_history')).single['id'], 'msg-1');
  });

  test('same session id from two devices has separate archive identity',
      () async {
    await catalog.addPendingPointer(pointer());
    await catalog.addPendingPointer(pointer(
      archiveId: 'snapshot-2',
      device: 'device-b',
      key: 'conversation/snapshot-2.enc',
    ));
    expect(
      await catalog.findByOrigin(
        originDeviceId: 'device-a',
        sessionId: 'default',
      ),
      hasLength(1),
    );
    expect(
      await catalog.findByOrigin(
        originDeviceId: 'device-b',
        sessionId: 'default',
      ),
      hasLength(1),
    );
    expect(await db.query(AppConstants.tableChatArchiveCatalog), hasLength(2));
  });

  test('immutable ID retries are safe; rewriting ciphertext is blocked',
      () async {
    await catalog.addPendingPointer(pointer());
    await catalog.addPendingPointer(pointer(created: 200));
    expect(await db.query(AppConstants.tableChatArchiveCatalog), hasLength(1));
    await expectLater(
      catalog.addPendingPointer(pointer(key: 'conversation/rewritten.enc')),
      throwsStateError,
    );
    expect((await catalog.findPointer('snapshot-1'))!.objectKey,
        'conversation/snapshot-1.enc');
  });

  test('verification cannot be claimed without a storage adapter', () async {
    await expectLater(
      catalog.addPendingPointer(pointer(verifiedAt: 123)),
      throwsArgumentError,
    );
    expect(await db.query(AppConstants.tableChatArchiveCatalog), isEmpty);
  });

  test('rejects corrupt hashes and unsafe object keys', () async {
    await expectLater(
      catalog.addPendingPointer(pointer(sha: 'not-a-digest')),
      throwsArgumentError,
    );
    for (final key in <String>[
      '../escape.enc',
      '/absolute/escape.enc',
      'https://secret.example/archive.enc',
      'folder/../../file.enc',
      'folder\\file.enc',
      'folder/file.enc?token=private',
    ]) {
      await expectLater(
        catalog.addPendingPointer(pointer(key: key)),
        throwsArgumentError,
      );
    }
    expect(await db.query(AppConstants.tableChatArchiveCatalog), isEmpty);
  });

  test('durable-memory source references locate the original message',
      () async {
    await catalog.addPendingPointer(pointer());
    const link = ChatArchiveMemoryLink(
      memoryScope: 'user',
      memoryKey: 'hardware.s24.model',
      archiveId: 'snapshot-1',
      messageId: 'msg-1',
    );
    await catalog.addMemorySource(link);
    await catalog.addMemorySource(link);
    final sources = await catalog.sourcesForMemory(
      memoryScope: 'user',
      memoryKey: 'hardware.s24.model',
    );
    expect(sources, hasLength(1));
    expect(sources.single.archiveId, 'snapshot-1');
    expect(sources.single.messageId, 'msg-1');
    expect(
      await catalog.sourcesForMemory(
        memoryScope: 'project',
        memoryKey: 'hardware.s24.model',
      ),
      isEmpty,
    );
    expect((await db.query('chat_history')).single['id'], 'msg-1');
  });

  test('cannot link memory to an unregistered archive', () async {
    await expectLater(
      catalog.addMemorySource(const ChatArchiveMemoryLink(
        memoryScope: 'user',
        memoryKey: 'example',
        archiveId: 'unknown',
        messageId: 'msg-1',
      )),
      throwsStateError,
    );
  });
}
