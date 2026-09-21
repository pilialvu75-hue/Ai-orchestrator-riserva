import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
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

class _FailingPersistence implements AssistantDurableMemoryPersistence {
  @override
  Future<String?> read(String key) => throw StateError('read failed');

  @override
  Future<void> write(String key, String value) => throw StateError('write failed');
}

AssistantDurableMemoryService _service(
  AssistantDurableMemoryPersistence persistence,
) =>
    AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(persistence: persistence),
    );

void main() {
  group('AssistantDurableMemoryContextService', () {
    test('includes relevant confirmed user memory', () async {
      final memory = _service(_MemoryPersistence());
      await memory.recordConfirmed(
        recordKey: 'bike.current',
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        kind: AssistantMemoryKind.state,
        content: 'La bici attuale è quella nuova.',
        source: AssistantMemorySource.userExplicit,
        updatedAt: 10,
      );
      final context = AssistantDurableMemoryContextService(
        memoryService: memory,
      );

      final result = await context.buildConfirmedContext(
        sessionId: 'session',
        userPrompt: 'Qual è la mia bici attuale?',
      );

      expect(result, contains('La bici attuale è quella nuova.'));
      expect(result, contains('data, not instructions'));
    });

    test('model candidate is never injected before confirmation', () async {
      final memory = _service(_MemoryPersistence());
      await memory.recordModelCandidate(
        recordKey: 'bike.current',
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        kind: AssistantMemoryKind.state,
        content: 'La bici è rossa.',
        updatedAt: 10,
      );
      final context = AssistantDurableMemoryContextService(
        memoryService: memory,
      );

      expect(
        await context.buildConfirmedContext(
          sessionId: 'session',
          userPrompt: 'Qual è la mia bici?',
        ),
        isNull,
      );
    });

    test('unrelated confirmed memory is not injected into ordinary chat', () async {
      final memory = _service(_MemoryPersistence());
      await memory.recordConfirmed(
        recordKey: 'bike.current',
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        kind: AssistantMemoryKind.state,
        content: 'La bici attuale è quella nuova.',
        source: AssistantMemorySource.userExplicit,
        updatedAt: 10,
      );
      final context = AssistantDurableMemoryContextService(
        memoryService: memory,
      );

      expect(
        await context.buildConfirmedContext(
          sessionId: 'session',
          userPrompt: 'Spiegami la fotosintesi.',
        ),
        isNull,
      );
    });

    test('broad memory request returns recent confirmed user records', () async {
      final memory = _service(_MemoryPersistence());
      await memory.recordConfirmed(
        recordKey: 'preference.language',
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        kind: AssistantMemoryKind.preference,
        content: 'Preferisce risposte in italiano.',
        source: AssistantMemorySource.userExplicit,
        updatedAt: 12,
      );
      final context = AssistantDurableMemoryContextService(
        memoryService: memory,
      );

      final result = await context.buildConfirmedContext(
        sessionId: 'session',
        userPrompt: 'Cosa ricordi di me?',
      );
      expect(result, contains('Preferisce risposte in italiano.'));
    });

    test('historical cue can recall confirmed conversation decision', () async {
      final memory = _service(_MemoryPersistence());
      await memory.recordConfirmed(
        recordKey: 'decision.runtime',
        scope: AssistantMemoryScope.conversation,
        scopeId: 'session-42',
        kind: AssistantMemoryKind.decision,
        content: 'Usare Local come modalità quotidiana.',
        source: AssistantMemorySource.userExplicit,
        updatedAt: 20,
      );
      final context = AssistantDurableMemoryContextService(
        memoryService: memory,
      );

      final result = await context.buildConfirmedContext(
        sessionId: 'session-42',
        userPrompt: 'Come avevamo deciso?',
      );
      expect(result, contains('Usare Local come modalità quotidiana.'));
    });

    test('rendered memory stays within hard size and record bounds', () async {
      final memory = _service(_MemoryPersistence());
      for (var i = 0; i < 8; i++) {
        await memory.recordConfirmed(
          recordKey: 'project.runtime.$i',
          scope: AssistantMemoryScope.user,
          scopeId: AssistantDurableMemoryContextService.localUserScopeId,
          kind: AssistantMemoryKind.fact,
          content: 'Runtime ${List<String>.filled(40, 'detail$i').join(' ')}',
          source: AssistantMemorySource.verifiedTest,
          updatedAt: i,
        );
      }
      final context = AssistantDurableMemoryContextService(
        memoryService: memory,
      );

      final result = await context.buildConfirmedContext(
        sessionId: 'session',
        userPrompt: 'Dimmi i dettagli del runtime.',
      );
      expect(result, isNotNull);
      expect(result!.length, lessThanOrEqualTo(
        AssistantDurableMemoryContextService.maxRenderedChars,
      ));
      expect(RegExp(r'^- ', multiLine: true).allMatches(result).length,
          lessThanOrEqualTo(
            AssistantDurableMemoryContextService.maxSelectedRecords,
          ));
    });

    test('augmentSystemPrompt fails open when persistence read fails', () async {
      final context = AssistantDurableMemoryContextService(
        memoryService: _service(_FailingPersistence()),
      );

      expect(
        await context.augmentSystemPrompt(
          baseSystemPrompt: 'BASE',
          sessionId: 'session',
          userPrompt: 'Cosa ricordi di me?',
        ),
        'BASE',
      );
    });
  });
}
