import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
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

AssistantDurableMemoryService _service() {
  return AssistantDurableMemoryService(
    store: AssistantDurableMemoryStore(
      persistence: _MemoryPersistence(),
    ),
  );
}

void main() {
  group('AssistantDurableMemoryService', () {
    test('records externally confirmed memory as confirmed', () async {
      final service = _service();

      await service.recordConfirmed(
        recordKey: 'bike.current',
        scope: AssistantMemoryScope.user,
        scopeId: 'local-user',
        kind: AssistantMemoryKind.state,
        content: 'La bici attuale è quella nuova.',
        source: AssistantMemorySource.userExplicit,
        updatedAt: 20,
        before: 'bici vecchia',
        after: 'bici nuova',
        reason: 'sostituzione confermata',
      );

      final records = await service.loadConfirmed(
        scope: AssistantMemoryScope.user,
        scopeId: 'local-user',
      );

      expect(records, hasLength(1));
      expect(records.single.status, AssistantMemoryStatus.confirmed);
      expect(records.single.source, AssistantMemorySource.userExplicit);
      expect(records.single.before, 'bici vecchia');
      expect(records.single.after, 'bici nuova');
    });

    test('model candidate is excluded until explicitly confirmed', () async {
      final service = _service();

      await service.recordModelCandidate(
        recordKey: 'project.runtime',
        scope: AssistantMemoryScope.project,
        scopeId: 'assistant',
        kind: AssistantMemoryKind.state,
        content: 'Vulkan seems enabled.',
        updatedAt: 10,
      );

      expect(
        await service.loadConfirmed(
          scope: AssistantMemoryScope.project,
          scopeId: 'assistant',
        ),
        isEmpty,
      );

      final confirmed = await service.confirmCandidate(
        scope: AssistantMemoryScope.project,
        scopeId: 'assistant',
        recordKey: 'project.runtime',
        confirmedAt: 11,
        confirmedSource: AssistantMemorySource.verifiedTest,
      );

      expect(confirmed, isTrue);
      final records = await service.loadConfirmed(
        scope: AssistantMemoryScope.project,
        scopeId: 'assistant',
      );
      expect(records, hasLength(1));
      expect(records.single.source, AssistantMemorySource.verifiedTest);
      expect(records.single.status, AssistantMemoryStatus.confirmed);
    });

    test('modelCandidate cannot be used as confirmed source', () async {
      final service = _service();

      expect(
        () => service.recordConfirmed(
          recordKey: 'unsafe',
          scope: AssistantMemoryScope.conversation,
          scopeId: 'session',
          kind: AssistantMemoryKind.fact,
          content: 'unverified',
          source: AssistantMemorySource.modelCandidate,
          updatedAt: 1,
        ),
        throwsArgumentError,
      );

      expect(
        () => service.confirmCandidate(
          scope: AssistantMemoryScope.conversation,
          scopeId: 'session',
          recordKey: 'unsafe',
          confirmedAt: 2,
          confirmedSource: AssistantMemorySource.modelCandidate,
        ),
        throwsArgumentError,
      );
    });

    test('loadConfirmed is bounded and newest-first', () async {
      final service = _service();

      for (var i = 0; i < 5; i++) {
        await service.recordConfirmed(
          recordKey: 'decision.$i',
          scope: AssistantMemoryScope.conversation,
          scopeId: 'session',
          kind: AssistantMemoryKind.decision,
          content: 'decision $i',
          source: AssistantMemorySource.userExplicit,
          updatedAt: i,
        );
      }

      final records = await service.loadConfirmed(
        scope: AssistantMemoryScope.conversation,
        scopeId: 'session',
        limit: 2,
      );

      expect(records.map((item) => item.recordKey), <String>[
        'decision.4',
        'decision.3',
      ]);
    });

    test('non-positive read limit returns no records', () async {
      final service = _service();

      await service.recordConfirmed(
        recordKey: 'fact',
        scope: AssistantMemoryScope.conversation,
        scopeId: 'session',
        kind: AssistantMemoryKind.fact,
        content: 'fact',
        source: AssistantMemorySource.appState,
        updatedAt: 1,
      );

      expect(
        await service.loadConfirmed(
          scope: AssistantMemoryScope.conversation,
          scopeId: 'session',
          limit: 0,
        ),
        isEmpty,
      );
    });
  });
}
