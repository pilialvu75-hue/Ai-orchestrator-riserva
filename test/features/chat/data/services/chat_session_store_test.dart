import 'package:ai_orchestrator/features/chat/data/services/chat_session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ChatSessionStore store;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE user_preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)
    ''');
    await db.execute('''
      CREATE TABLE chat_sessions (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE chat_history (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        timestamp INTEGER NOT NULL
      )
    ''');
    store = ChatSessionStore.forTesting(db);
  });

  tearDown(() async => db.close());

  Future<void> addMessage(
    String id,
    String sessionId,
    int timestamp,
    String text,
  ) async {
    await db.insert('chat_history', <String, Object>{
      'id': id,
      'session_id': sessionId,
      'role': 'user',
      'content': text,
      'timestamp': timestamp,
    });
  }

  test('new session preserves previously stored messages', () async {
    await store.createSession('default');
    await addMessage('old-message', 'default', 10, 'Prima conversazione');
    await store.createSession('new-session');
    await store.selectSession('new-session');

    expect(await db.query('chat_history'), hasLength(1));
    expect((await store.listSessions()), hasLength(2));
    expect(await store.restoreActiveSession(), 'new-session');
    expect((await store.listSessions()).last.title, 'Prima conversazione');
  });

  test('most recent first, with pinned sessions always before other chats',
      () async {
    await store.createSession('a');
    await store.createSession('b');
    await store.createSession('c');
    await addMessage('m1', 'a', 100, 'Prima chat');
    await addMessage('m2', 'b', 300, 'Ultima chat');
    await addMessage('m3', 'c', 200, 'Altra chat');

    expect(
      (await store.listSessions()).map((s) => s.id).toList(),
      <String>['b', 'c', 'a'],
    );

    await store.setPinned('a', true);
    expect(
      (await store.listSessions()).map((s) => s.id).toList(),
      <String>['a', 'b', 'c'],
    );
    await store.setPinned('a', false);
    expect(
      (await store.listSessions()).map((s) => s.id).toList(),
      <String>['b', 'c', 'a'],
    );
  });

  test('titles are derived from user prompts and not model output', () async {
    await store.createSession('s1');
    await db.insert('chat_history', <String, Object>{
      'id': 'model1',
      'session_id': 's1',
      'role': 'assistant',
      'content': 'Model hallucination as title',
      'timestamp': 1,
    });
    await addMessage('user1', 's1', 2, 'Come funziona la memoria locale?');
    final sessions = await store.listSessions();
    expect(sessions.single.title, 'Come funziona la memoria locale?');
  });

  test('restores legacy default chat without dropping any messages', () async {
    await addMessage('legacy', 'default', 123, 'Il nostro primo messaggio');
    await db.rawInsert('''
      INSERT OR IGNORE INTO chat_sessions (id, created_at, pinned)
      SELECT session_id, MIN(timestamp), 0
      FROM chat_history
      GROUP BY session_id
    ''');
    expect(await store.restoreActiveSession(), 'default');
    expect((await store.listSessions()).single.title,
        'Il nostro primo messaggio');
    expect(await db.query('chat_history'), hasLength(1));
  });

  test('empty chats stay available across restoration', () async {
    await store.createSession('fresh');
    await store.selectSession('fresh');
    final renewed = ChatSessionStore.forTesting(db);
    expect(await renewed.restoreActiveSession(), 'fresh');
    expect((await renewed.listSessions()).single.title, 'Nuova chat');
  });
}
