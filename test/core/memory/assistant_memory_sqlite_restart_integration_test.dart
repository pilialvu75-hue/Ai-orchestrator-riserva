import 'dart:io';

import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// File-backed SQLite, never the user's installed app database.
///
/// Closing and reopening the database simulates persistence across an
/// application restart; this does NOT claim a physical device acceptance.
void main() {
  late Directory scratch;
  late String databasePath;
  late Database database;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<Database> openTestDatabase() async {
    final opened = await databaseFactoryFfi.openDatabase(databasePath);
    // Only the existing preferences table is required by durable memory.
    // Production schema and any user files remain untouched.
    await opened.execute('''
      CREATE TABLE IF NOT EXISTS user_preferences (
        pref_key TEXT PRIMARY KEY,
        pref_value TEXT NOT NULL DEFAULT ''
      )
    ''');
    return opened;
  }

  AssistantDurableMemoryService makeMemory() {
    final helper = DatabaseHelper.forTesting(database);
    return AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(
        persistence: SqliteAssistantDurableMemoryPersistence(
          databaseHelper: helper,
        ),
      ),
    );
  }

  Future<void> reopen() async {
    await database.close();
    database = await openTestDatabase();
  }

  Future<String> promptFor(
    AssistantDurableMemoryService memory, {
    required String sessionId,
    required String question,
  }) {
    return AssistantDurableMemoryContextService(
      memoryService: memory,
    ).augmentSystemPrompt(
      baseSystemPrompt: 'You are an assistant.',
      sessionId: sessionId,
      userPrompt: question,
    );
  }

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('aivexus-memory-restart-');
    databasePath = '${scratch.path}/durable_memory.sqlite';
    database = await openTestDatabase();
  });

  tearDown(() async {
    if (database.isOpen) await database.close();
    await scratch.delete(recursive: true);
  });

  test('explicit user fact persists across reopen, update and forget',
      () async {
    final memory = makeMemory();
    final capture = AssistantDurableMemoryCaptureService(
      memoryService: memory,
    );

    expect(
      await capture.applyExplicitUserInstruction(
        sessionId: 'first-chat',
        userPrompt: 'Ricorda che il budget è 420',
      ),
      isTrue,
    );

    await reopen();
    var currentMemory = makeMemory();
    var prompt = await promptFor(
      currentMemory,
      sessionId: 'second-chat',
      question: 'Qual è il budget?',
    );
    expect(prompt, contains('il budget è 420'));

    final revisedCapture = AssistantDurableMemoryCaptureService(
      memoryService: currentMemory,
    );
    expect(
      await revisedCapture.applyExplicitUserInstruction(
        sessionId: 'second-chat',
        userPrompt: 'Ricorda che il budget è 680',
      ),
      isTrue,
    );

    await reopen();
    currentMemory = makeMemory();
    prompt = await promptFor(
      currentMemory,
      sessionId: 'third-chat',
      question: 'Qual è il budget?',
    );
    expect(prompt, contains('il budget è 680'));
    expect(prompt, isNot(contains('il budget è 420')));

    final forgetCapture = AssistantDurableMemoryCaptureService(
      memoryService: currentMemory,
    );
    expect(
      await forgetCapture.applyExplicitUserInstruction(
        sessionId: 'third-chat',
        userPrompt: 'Dimentica il budget',
      ),
      isTrue,
    );

    await reopen();
    prompt = await promptFor(
      makeMemory(),
      sessionId: 'fourth-chat',
      question: 'Qual è il budget?',
    );
    expect(prompt, isNot(contains('CONFIRMED DURABLE MEMORY')));
    expect(prompt, isNot(contains('680')));
    expect(prompt, isNot(contains('420')));
  });

  test('natural remember phrasing survives SQLite reopen and replaces stale value',
      () async {
    final initialCapture = AssistantDurableMemoryCaptureService(
      memoryService: makeMemory(),
    );
    expect(
      await initialCapture.applyExplicitUserInstruction(
        sessionId: 'windows-chat',
        userPrompt: 'Ricorda che il budget prova Windows è 731',
      ),
      isTrue,
    );
    await reopen();
    final nextCapture = AssistantDurableMemoryCaptureService(
      memoryService: makeMemory(),
    );
    expect(
      await nextCapture.applyExplicitUserInstruction(
        sessionId: 'windows-chat',
        userPrompt: 'ricorda il budget prova Windows è 732',
      ),
      isTrue,
    );
    await reopen();
    final prompt = await promptFor(
      makeMemory(),
      sessionId: 'other-chat',
      question: 'Qual è il budget prova Windows?',
    );
    expect(prompt, contains('il budget prova Windows è 732'));
    expect(prompt, isNot(contains('il budget prova Windows è 731')));
  });

  test('conversation-only memory survives restart but never leaks to others',
      () async {
    final memory = makeMemory();
    final capture = AssistantDurableMemoryCaptureService(
      memoryService: memory,
    );
    expect(
      await capture.applyExplicitUserInstruction(
        sessionId: 'moto-chat',
        userPrompt: 'Ricorda solo in questa chat che la moto è rossa',
      ),
      isTrue,
    );

    await reopen();
    final reloadedMemory = makeMemory();
    final same = await promptFor(
      reloadedMemory,
      sessionId: 'moto-chat',
      question: 'Qual è il colore della moto?',
    );
    expect(same, contains('la moto è rossa'));

    final separate = await promptFor(
      reloadedMemory,
      sessionId: 'new-chat',
      question: 'Qual è il colore della moto?',
    );
    expect(separate, isNot(contains('la moto è rossa')));

    final userRecords = await reloadedMemory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
    );
    expect(userRecords, isEmpty);
  });

  test('model-only candidates stay excluded from retrieved context on reopen',
      () async {
    final memory = makeMemory();
    await memory.recordModelCandidate(
      recordKey: 'madeup.tram',
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      kind: AssistantMemoryKind.fact,
      content: 'Il tram di prova passa alle 4:44',
      updatedAt: 1,
    );

    await reopen();
    final prompt = await promptFor(
      makeMemory(),
      sessionId: 'other-chat',
      question: 'A che ora passa il tram di prova?',
    );
    expect(prompt, isNot(contains('4:44')));
    expect(prompt, isNot(contains('CONFIRMED DURABLE MEMORY')));
  });
  test('approved and corrected candidate survives SQLite reopen',
      () async {
    final staged = AssistantDurableMemoryCaptureService(
      memoryService: makeMemory(),
    );
    expect(
      await staged.proposeUserPreferenceCandidate(
        userPrompt: 'Preferisco risposte brevi',
        consentEnabled: true,
      ),
      isTrue,
    );

    await reopen();
    final review = AssistantDurableMemoryCaptureService(
      memoryService: makeMemory(),
    );
    final before = await promptFor(
      makeMemory(),
      sessionId: 'other-chat',
      question: 'Quali risposte preferisco?',
    );
    expect(before, isNot(contains('CONFIRMED DURABLE MEMORY')));
    final pending = (await review.loadReviewablePreferenceCandidates()).single;
    expect(
      await review.reviewUserPreferenceCandidate(
        reviewed: pending,
        approve: true,
        correctedContent: 'Preferisco risposte dettagliate',
        userConfirmed: true,
      ),
      isTrue,
    );

    await reopen();
    final accepted = await promptFor(
      makeMemory(),
      sessionId: 'third-chat',
      question: 'Quali risposte preferisco?',
    );
    expect(accepted, contains('Preferisco risposte dettagliate'));
    expect(accepted, isNot(contains('Preferisco risposte brevi')));
    expect(
      await AssistantDurableMemoryCaptureService(
        memoryService: makeMemory(),
      ).loadReviewablePreferenceCandidates(),
      isEmpty,
    );
  });


}
