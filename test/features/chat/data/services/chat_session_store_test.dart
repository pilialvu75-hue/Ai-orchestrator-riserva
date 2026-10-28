import 'package:ai_orchestrator/core/database/database_helper.dart';
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
      CREATE TABLE user_preferences (pref_key TEXT PRIMARY KEY, pref_value TEXT NOT NULL)
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

  test('manual title persists after restore without changing chat messages',
      () async {
    await store.createSession('a');
    await addMessage('m1', 'a', 10, 'Messaggio originale');
    await store.renameSession('a', '  Titolo scelto  ');
    expect((await store.listSessions()).single.title, 'Titolo scelto');

    final reopenedStore = ChatSessionStore.forTesting(db);
    expect((await reopenedStore.listSessions()).single.title, 'Titolo scelto');
    expect((await db.query('chat_history')).single['content'],
        'Messaggio originale');

    await store.renameSession('a', 'Titolo aggiornato');
    expect((await store.listSessions()).single.title, 'Titolo aggiornato');
  });

  test('renaming one chat preserves all other titles and pins', () async {
    await store.createSession('a');
    await store.createSession('b');
    await addMessage('m1', 'a', 1, 'Chat A');
    await addMessage('m2', 'b', 2, 'Chat B');
    await store.setPinned('a', true);
    await store.renameSession('b', 'Conversazione B');
    final sessions = await store.listSessions();
    expect(sessions.map((s) => s.id), <String>['a', 'b']);
    expect(sessions.first.title, 'Chat A');
    expect(sessions.first.pinned, isTrue);
    expect(sessions.last.title, 'Conversazione B');
    expect((await db.query('chat_history')).length, 2);
  });

  test('invalid titles and missing sessions do not change stored history',
      () async {
    await store.createSession('a');
    await addMessage('m1', 'a', 1, 'Messaggio intatto');
    await expectLater(store.renameSession('a', '   '), throwsArgumentError);
    await expectLater(
      store.renameSession('a', List<String>.filled(81, 'x').join()),
      throwsArgumentError,
    );
    await expectLater(
      store.renameSession('missing', 'Un titolo'),
      throwsStateError,
    );
    expect((await store.listSessions()).single.title, 'Messaggio intatto');
    expect((await db.query('chat_history')).single['content'],
        'Messaggio intatto');
  });

  test('explicit chat-history wipe clears custom titles but no other settings',
      () async {
    await store.createSession('a');
    await addMessage('m1', 'a', 10, 'La prima chat');
    await store.renameSession('a', 'Nome privato');
    await db.insert('user_preferences', <String, Object>{
      'pref_key': 'user.theme',
      'pref_value': 'dark',
    });

    final helper = DatabaseHelper.forTesting(db);
    expect(await helper.deleteAllChatMessages(), 1);
    expect(await db.query('chat_sessions'), isEmpty);
    expect(await db.query('chat_history'), isEmpty);
    final preferences = await db.query('user_preferences');
    expect(preferences, hasLength(1));
    expect(preferences.single['pref_key'], 'user.theme');
    expect(preferences.single['pref_value'], 'dark');
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

  test('trash hides a chat but keeps messages, title and pinned state', () async {
    await store.createSession('s1');
    await store.createSession('s2');
    await addMessage('one', 's1', 10, 'Messaggio privato');
    await addMessage('two', 's2', 11, 'Altra chat');
    await store.renameSession('s1', 'Titolo scelto');
    await store.setPinned('s1', true);

    await store.moveToTrash('s1');
    expect((await store.listSessions()).map((s) => s.id), <String>['s2']);
    final trash = await store.listSessions(inTrash: true);
    expect(trash.single.id, 's1');
    expect(trash.single.title, 'Titolo scelto');
    expect(trash.single.pinned, isTrue);
    expect(await db.query('chat_history'), hasLength(2));

    // The trash marker survives recreating the store over the same SQLite DB.
    final reopened = ChatSessionStore.forTesting(db);
    expect((await reopened.listSessions(inTrash: true)).single.id, 's1');

    await reopened.restoreFromTrash('s1');
    expect((await store.listSessions()).map((s) => s.id),
        <String>['s1', 's2']);
    expect((await store.listSessions(inTrash: true)), isEmpty);
    expect((await db.query('chat_history')).length, 2);
    expect((await store.listSessions()).first.title, 'Titolo scelto');
  });

  test('trash of active default cannot silently revive its old conversation',
      () async {
    await store.createSession('default');
    await addMessage('m1', 'default', 10, 'Contenuto da conservare');
    await store.selectSession('default');
    await store.moveToTrash('default');

    final restoredActive = await store.restoreActiveSession();
    expect(restoredActive, isNot('default'));
    expect((await store.listSessions()).single.id, restoredActive);
    expect((await store.listSessions(inTrash: true)).single.id, 'default');
    expect((await db.query('chat_history')).single['content'],
        'Contenuto da conservare');
  });

  test('trash of selected chat switches to an existing visible chat', () async {
    await store.createSession('a');
    await store.createSession('b');
    await store.selectSession('a');
    await store.moveToTrash('a');

    expect(await store.restoreActiveSession(), 'b');
    expect((await store.listSessions(inTrash: true)).single.id, 'a');
    expect((await store.listSessions()).single.id, 'b');
  });

  test('trash refuses missing session without creating dangling markers',
      () async {
    await expectLater(store.moveToTrash('missing'), throwsStateError);
    expect(await store.listSessions(inTrash: true), isEmpty);
    expect(await db.query('user_preferences'), isEmpty);
  });
}
