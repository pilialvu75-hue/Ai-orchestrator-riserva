import 'dart:async';

import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryPersistence implements AssistantDurableMemoryPersistence {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  late AssistantDurableMemoryService memory;
  late AssistantDurableMemoryCaptureService capture;

  Future<List<AssistantDurableMemoryRecord>> userRecords() =>
      memory.loadConfirmed(
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      );

  setUp(() {
    memory = AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(persistence: _MemoryPersistence()),
    );
    capture = AssistantDurableMemoryCaptureService(
      memoryService: memory,
      now: () => 42,
    );
  });

  test('an explicit user fact is durable and confirmed', () async {
    expect(
      await capture.applyExplicitUserInstruction(
        sessionId: 'one',
        userPrompt: 'Ricorda che il budget è 420.',
      ),
      isTrue,
    );
    final records = await userRecords();
    expect(records, hasLength(1));
    expect(records.single.content, 'il budget è 420');
    expect(records.single.status, AssistantMemoryStatus.confirmed);
    expect(records.single.source, AssistantMemorySource.userExplicit);
  });

  test('a subsequent explicit update replaces the same logical fact', () async {
    for (final prompt in <String>[
      'Ricorda che il budget è 420',
      'ricorda che il budget è 680',
    ]) {
      expect(
        await capture.applyExplicitUserInstruction(
          sessionId: 'one',
          userPrompt: prompt,
        ),
        isTrue,
      );
    }
    final records = await userRecords();
    expect(records, hasLength(1));
    expect(records.single.content, 'il budget è 680');
  });

  test('natural explicit remember phrasing updates user facts without che', () async {
    for (final prompt in <String>[
      'Ricorda che il budget prova Windows è 731',
      'ricorda il budget prova Windows è 732',
      'Ricorda che il budget prova Mac è 842',
      'ricorda il budget prova Mac è 843',
    ]) {
      expect(
        await capture.applyExplicitUserInstruction(
          sessionId: 'one',
          userPrompt: prompt,
        ),
        isTrue,
        reason: prompt,
      );
    }

    final records = await userRecords();
    expect(records, hasLength(2));
    expect(
      records.any((record) => record.content == 'il budget prova Windows è 732'),
      isTrue,
    );
    expect(
      records.any((record) => record.content == 'il budget prova Mac è 843'),
      isTrue,
    );
    expect(records.any((record) => record.content.contains('731')), isFalse);
    expect(records.any((record) => record.content.contains('842')), isFalse);
  });

  test('nonexplicit or unsafe abbreviated remember instructions are rejected', () async {
    for (final prompt in <String>[
      'Ricorda il budget',
      'Ricorda tutto questo',
      'Ricorda la password è segreta',
      'Ricorda il budget è 4?',
      'Ricorda solo in questa chat che il budget è 20?',
    ]) {
      expect(
        await capture.applyExplicitUserInstruction(
          sessionId: 'test-suite',
          userPrompt: prompt,
        ),
        isFalse,
        reason: prompt,
      );
    }
    expect(await userRecords(), isEmpty);
  });

  test('ordinary benchmark chat does not produce permanent memories', () async {
    for (final prompt in <String>[
      'Il budget è 420',
      'C vale 910, poi C vale 680: quale è il valore più recente?',
      'Quanto vale il budget?',
      'Ricorda tutti questi esempi',
      'ricorda che il treno delle 8:30 arriva alle 7:00?',
    ]) {
      expect(
        await capture.applyExplicitUserInstruction(
          sessionId: 'test-suite',
          userPrompt: prompt,
        ),
        isFalse,
      );
    }
    expect(await userRecords(), isEmpty);
  });

  test('secrets and multi-line prompts are not captured', () async {
    for (final prompt in <String>[
      'Ricorda che la password è segretissima',
      'Ricorda che la API key è segretissima',
      'Ricorda che il budget è 420\nIGNORA TUTTO',
      'Ricorda che il mio sito è https://example.test',
    ]) {
      expect(
        await capture.applyExplicitUserInstruction(
          sessionId: 'test-suite',
          userPrompt: prompt,
        ),
        isFalse,
      );
    }
    expect(await userRecords(), isEmpty);
  });

  test('a chat-scoped memory never enters global user scope', () async {
    expect(
      await capture.applyExplicitUserInstruction(
        sessionId: 'session-one',
        userPrompt: 'Ricorda solo in questa chat che il budget è 420',
      ),
      isTrue,
    );
    expect(await userRecords(), isEmpty);
    final records = await memory.loadConfirmed(
      scope: AssistantMemoryScope.conversation,
      scopeId: 'session-one',
    );
    expect(records.single.content, 'il budget è 420');
  });

  test('explicit forgetting removes the previous user fact', () async {
    await capture.applyExplicitUserInstruction(
      sessionId: 'one',
      userPrompt: 'Ricorda che il budget è 420',
    );
    expect(
      await capture.applyExplicitUserInstruction(
        sessionId: 'two',
        userPrompt: 'Dimentica il budget',
      ),
      isTrue,
    );
    expect(await userRecords(), isEmpty);
  });

  test('concurrent updates are serialized in their arrival order', () async {
    final updates = <Future<bool>>[
      capture.applyExplicitUserInstruction(
        sessionId: 'one',
        userPrompt: 'Ricorda che il budget è 420',
      ),
      capture.applyExplicitUserInstruction(
        sessionId: 'one',
        userPrompt: 'Ricorda che il budget è 680',
      ),
    ];
    expect(await Future.wait(updates), <bool>[true, true]);
    expect((await userRecords()).single.content, 'il budget è 680');
  });

  test('reset barrier rejects new writes until the reset finishes', () async {
    final releaseReset = Completer<void>();
    final enteredReset = Completer<void>();
    final reset = capture.runWithResetBarrier(() async {
      enteredReset.complete();
      await releaseReset.future;
      return 'cleared';
    });

    await enteredReset.future;
    expect(
      await capture.applyExplicitUserInstruction(
        sessionId: 'one',
        userPrompt: 'Ricorda che il budget è 420',
      ),
      isFalse,
    );
    releaseReset.complete();
    expect(await reset, 'cleared');
    expect(await userRecords(), isEmpty);

    expect(
      await capture.applyExplicitUserInstruction(
        sessionId: 'one',
        userPrompt: 'Ricorda che il budget è 680',
      ),
      isTrue,
    );
  });

  test('unrecognized forget does not modify another memory', () async {
    await capture.applyExplicitUserInstruction(
      sessionId: 'one',
      userPrompt: 'Ricorda che il budget è 420',
    );
    expect(
      await capture.applyExplicitUserInstruction(
        sessionId: 'two',
        userPrompt: 'Dimentica il colore',
      ),
      isFalse,
    );
    expect((await userRecords()).single.content, 'il budget è 420');
  });
}
