import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_snapshot_store.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_session_store.dart';
import 'package:ai_orchestrator/features/chat/data/services/hybrid_local_session_authorizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _ProtectedMemoryBackend implements HybridProtectedSnapshotBackend {
  final Map<String, String> values = <String, String>{};
  bool failWrite = false;
  bool hideReads = false;

  @override
  Future<String?> read(String key) async => hideReads ? null : values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('Secure storage unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  late Database db;
  late ChatSessionStore sessions;
  late _ProtectedMemoryBackend protected;
  late HybridLocalSessionAuthorizer auth;

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
        id TEXT PRIMARY KEY, created_at INTEGER NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE chat_history (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
        role TEXT NOT NULL, content TEXT NOT NULL DEFAULT '',
        timestamp INTEGER NOT NULL
      )
    ''');
    sessions = ChatSessionStore.forTesting(db);
    protected = _ProtectedMemoryBackend();
    auth = HybridLocalSessionAuthorizer(
      backend: protected, sessions: sessions,
    );
  });

  tearDown(() async => db.close());

  test('no implicit owner enrollment during authorization', () async {
    await sessions.createSession('original-chat');
    expect(await auth.authorizeOwnerSession(
      'invalid-owner', 'original-chat'), isFalse);
    expect(protected.values, isEmpty);
  });

  test('local OS-protected owner is stable across authorizer instances',
      () async {
    final owner = await auth.initializeLocalOwner();
    expect(owner, matches(RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    )));
    expect(await auth.initializeLocalOwner(), owner);
    final restarted = HybridLocalSessionAuthorizer(
      backend: protected, sessions: ChatSessionStore.forTesting(db),
    );
    expect(await restarted.initializeLocalOwner(), owner);
    expect(protected.values, hasLength(1));
    await sessions.createSession('original-chat');
    expect(await restarted.authorizeOwnerSession(
      owner, 'original-chat'), isTrue);
  });

  test('different owner, missing chat and trash all fail closed', () async {
    final owner = await auth.initializeLocalOwner();
    await sessions.createSession('original-chat');
    await sessions.createSession('other-chat');
    expect(await auth.authorizeOwnerSession(
      owner, 'original-chat'), isTrue);
    expect(await auth.authorizeOwnerSession(
      owner, 'unknown-chat'), isFalse);
    expect(await auth.authorizeOwnerSession(
      'not-the-device-owner', 'original-chat'), isFalse);
    await sessions.moveToTrash('original-chat');
    expect(await auth.authorizeOwnerSession(
      owner, 'original-chat'), isFalse);
    expect(await auth.authorizeOwnerSession(
      owner, 'other-chat'), isTrue);
    await sessions.restoreFromTrash('original-chat');
    expect(await auth.authorizeOwnerSession(
      owner, 'original-chat'), isTrue);
  });

  test('failed protected write never creates a trusted local owner',
      () async {
    protected.failWrite = true;
    await expectLater(auth.initializeLocalOwner(), throwsStateError);
    protected.failWrite = false;
    expect(protected.values, isEmpty);
    await sessions.createSession('original-chat');
    expect(await auth.authorizeOwnerSession(
      'invalid-owner', 'original-chat'), isFalse);
  });

  test('unconfirmed protected readback denies enrollment and authorization',
      () async {
    protected.hideReads = true;
    await expectLater(auth.initializeLocalOwner(), throwsStateError);
    expect(protected.values, hasLength(1));
    protected.hideReads = false;
    final recovered = await auth.initializeLocalOwner();
    expect(await auth.authorizeOwnerSession(
      recovered, 'unknown-chat'), isFalse);
    await sessions.createSession('original-chat');
    expect(await auth.authorizeOwnerSession(
      recovered, 'original-chat'), isTrue);
  });

  test('corrupted protected owner refuses authentication, never regenerates',
      () async {
    await auth.initializeLocalOwner();
    final key = protected.values.keys.single;
    protected.values[key] = 'corrupted-identity';
    await sessions.createSession('original-chat');
    expect(await auth.authorizeOwnerSession(
      'corrupted-identity', 'original-chat'), isFalse);
    await expectLater(auth.initializeLocalOwner(), throwsStateError);
    expect(protected.values[key], 'corrupted-identity');
  });
}
