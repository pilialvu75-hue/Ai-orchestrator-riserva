import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
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

// Snapshot a read before yielding to expose lost updates in unguarded
// read-modify-write implementations. The production SQLite write is atomic,
// but separate callers can otherwise overwrite each other's earlier read.
class _DelayedMemoryPersistence extends _MemoryPersistence {
  @override
  Future<String?> read(String key) async {
    final snapshot = values[key];
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return snapshot;
  }
}

class _FailOnceMemoryPersistence extends _DelayedMemoryPersistence {
  bool failNextWrite = true;

  @override
  Future<void> write(String key, String value) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('simulated persistence failure');
    }
    await super.write(key, value);
  }
}

AssistantDurableMemoryRecord _record({
  String recordKey = 'project.pr514.status',
  AssistantMemoryStatus status = AssistantMemoryStatus.candidate,
  String content = 'Conditional chronological recall is under validation.',
  int updatedAt = 1,
  String? before,
  String? after,
  String? reason,
}) {
  return AssistantDurableMemoryRecord(
    recordKey: recordKey,
    scope: AssistantMemoryScope.project,
    scopeId: 'Ai-orchestrator-riserva',
    kind: AssistantMemoryKind.transition,
    content: content,
    source: AssistantMemorySource.verifiedTest,
    updatedAt: updatedAt,
    status: status,
    before: before,
    after: after,
    reason: reason,
  );
}

void main() {
  group('AssistantDurableMemoryStore', () {
    test('candidate memory is hidden until explicitly confirmed', () async {
      final persistence = _MemoryPersistence();
      final store = AssistantDurableMemoryStore(persistence: persistence);

      await store.upsert(_record());

      expect(
        await store.load(
          scope: AssistantMemoryScope.project,
          scopeId: 'Ai-orchestrator-riserva',
        ),
        isEmpty,
      );

      expect(
        await store.confirm(
          scope: AssistantMemoryScope.project,
          scopeId: 'Ai-orchestrator-riserva',
          recordKey: 'project.pr514.status',
          confirmedAt: 2,
          confirmedSource: AssistantMemorySource.verifiedTest,
        ),
        isTrue,
      );

      final confirmed = await store.load(
        scope: AssistantMemoryScope.project,
        scopeId: 'Ai-orchestrator-riserva',
      );
      expect(confirmed, hasLength(1));
      expect(confirmed.single.status, AssistantMemoryStatus.confirmed);
      expect(confirmed.single.updatedAt, 2);
    });


    test('model candidate cannot self-promote to confirmed memory', () async {
      final persistence = _MemoryPersistence();
      final store = AssistantDurableMemoryStore(persistence: persistence);

      final candidate = _record(
        status: AssistantMemoryStatus.confirmed,
      ).copyWith(source: AssistantMemorySource.modelCandidate);

      await expectLater(
        store.upsert(candidate),
        throwsArgumentError,
      );
    });


    test('model candidate can only be promoted by an external source', () async {
      final persistence = _MemoryPersistence();
      final store = AssistantDurableMemoryStore(persistence: persistence);
      final candidate = _record().copyWith(
        source: AssistantMemorySource.modelCandidate,
      );
      await store.upsert(candidate);

      await expectLater(
        store.confirm(
          scope: AssistantMemoryScope.project,
          scopeId: 'Ai-orchestrator-riserva',
          recordKey: candidate.recordKey,
          confirmedAt: 2,
          confirmedSource: AssistantMemorySource.modelCandidate,
        ),
        throwsArgumentError,
      );

      expect(
        await store.confirm(
          scope: AssistantMemoryScope.project,
          scopeId: 'Ai-orchestrator-riserva',
          recordKey: candidate.recordKey,
          confirmedAt: 3,
          confirmedSource: AssistantMemorySource.userExplicit,
        ),
        isTrue,
      );

      final confirmed = await store.load(
        scope: AssistantMemoryScope.project,
        scopeId: 'Ai-orchestrator-riserva',
      );
      expect(confirmed.single.source, AssistantMemorySource.userExplicit);
    });

    test('same logical key replaces stale state instead of accumulating', () async {
      final persistence = _MemoryPersistence();
      final store = AssistantDurableMemoryStore(persistence: persistence);

      await store.upsert(
        _record(
          status: AssistantMemoryStatus.confirmed,
          content: 'PR #514 test failed.',
          updatedAt: 10,
          before: 'tests running',
          after: '1 test failed',
          reason: 'portable recall envelope was applied too late',
        ),
      );

      await store.upsert(
        _record(
          status: AssistantMemoryStatus.confirmed,
          content: 'PR #514 recall fix is validated.',
          updatedAt: 20,
          before: '1 test failed',
          after: 'tests green',
          reason: 'dedupe now uses the portable recent window',
        ),
      );

      final records = await store.load(
        scope: AssistantMemoryScope.project,
        scopeId: 'Ai-orchestrator-riserva',
      );

      expect(records, hasLength(1));
      expect(records.single.content, 'PR #514 recall fix is validated.');
      expect(records.single.before, '1 test failed');
      expect(records.single.after, 'tests green');
    });

    test('rejects raw oversized content instead of turning logs into memory',
        () async {
      final persistence = _MemoryPersistence();
      final store = AssistantDurableMemoryStore(persistence: persistence);

      final oversized = List<String>.filled(
        AssistantDurableMemoryPolicy.maxContentChars + 1,
        'x',
      ).join();

      await expectLater(
        store.upsert(_record(content: oversized)),
        throwsArgumentError,
      );
    });

    test('retains only the newest bounded records per scope', () async {
      final persistence = _MemoryPersistence();
      final store = AssistantDurableMemoryStore(persistence: persistence);

      for (var index = 0;
          index < AssistantDurableMemoryPolicy.maxRecordsPerScope + 3;
          index++) {
        await store.upsert(
          _record(
            recordKey: 'state.$index',
            status: AssistantMemoryStatus.confirmed,
            content: 'state $index',
            updatedAt: index,
          ),
        );
      }

      final records = await store.load(
        scope: AssistantMemoryScope.project,
        scopeId: 'Ai-orchestrator-riserva',
      );

      expect(records,
          hasLength(AssistantDurableMemoryPolicy.maxRecordsPerScope));
      expect(records.first.recordKey,
          'state.${AssistantDurableMemoryPolicy.maxRecordsPerScope + 2}');
      expect(records.last.recordKey, 'state.3');
    });

    test('malformed persisted payload fails closed', () async {
      final persistence = _MemoryPersistence();
      final store = AssistantDurableMemoryStore(persistence: persistence);
      persistence.values[
          'assistant.durable_memory.v1:project:Ai-orchestrator-riserva'] =
          '{not-json';

      final records = await store.load(
        scope: AssistantMemoryScope.project,
        scopeId: 'Ai-orchestrator-riserva',
      );

      expect(records, isEmpty);
    });


    test('oversized persisted record is ignored on read', () async {
      final persistence = _MemoryPersistence();
      final store = AssistantDurableMemoryStore(persistence: persistence);
      final oversized = List<String>.filled(
        AssistantDurableMemoryPolicy.maxContentChars + 1,
        'x',
      ).join();

      persistence.values[
          'assistant.durable_memory.v1:project:Ai-orchestrator-riserva'] =
          '[{"recordKey":"bad","scope":"project","scopeId":"Ai-orchestrator-riserva","kind":"fact","content":"$oversized","source":"verifiedTest","updatedAt":1,"status":"confirmed"}]';

      expect(
        await store.load(
          scope: AssistantMemoryScope.project,
          scopeId: 'Ai-orchestrator-riserva',
        ),
        isEmpty,
      );
    });

    test('remove deletes only the selected logical record', () async {
      final persistence = _MemoryPersistence();
      final store = AssistantDurableMemoryStore(persistence: persistence);

      await store.upsert(
        _record(
          recordKey: 'state.a',
          status: AssistantMemoryStatus.confirmed,
        ),
      );
      await store.upsert(
        _record(
          recordKey: 'state.b',
          status: AssistantMemoryStatus.confirmed,
          updatedAt: 2,
        ),
      );

      expect(
        await store.remove(
          scope: AssistantMemoryScope.project,
          scopeId: 'Ai-orchestrator-riserva',
          recordKey: 'state.a',
        ),
        isTrue,
      );

      final records = await store.load(
        scope: AssistantMemoryScope.project,
        scopeId: 'Ai-orchestrator-riserva',
      );
      expect(records.map((item) => item.recordKey), ['state.b']);
    });

    test('concurrent updates to one scope preserve distinct keys', () async {
      final store = AssistantDurableMemoryStore(
        persistence: _DelayedMemoryPersistence(),
      );

      await Future.wait<void>([
        store.upsert(_record(recordKey: 'state.a', updatedAt: 1)),
        store.upsert(_record(recordKey: 'state.b', updatedAt: 2)),
      ]);

      final records = await store.load(
        scope: AssistantMemoryScope.project,
        scopeId: 'Ai-orchestrator-riserva',
        confirmedOnly: false,
      );
      expect(records.map((item) => item.recordKey).toSet(),
          {'state.a', 'state.b'});
    });

    test('confirm, forget and add do not lose unrelated memory', () async {
      final store = AssistantDurableMemoryStore(
        persistence: _DelayedMemoryPersistence(),
      );
      await store.upsert(_record(recordKey: 'state.confirm'));
      await store.upsert(_record(recordKey: 'state.forget'));

      final confirmed = store.confirm(
        scope: AssistantMemoryScope.project,
        scopeId: 'Ai-orchestrator-riserva',
        recordKey: 'state.confirm',
        confirmedAt: 3,
        confirmedSource: AssistantMemorySource.userExplicit,
      );
      final removed = store.remove(
        scope: AssistantMemoryScope.project,
        scopeId: 'Ai-orchestrator-riserva',
        recordKey: 'state.forget',
      );
      final inserted = store.upsert(
        _record(recordKey: 'state.new', updatedAt: 4),
      );
      await Future.wait<void>([
        confirmed.then<void>((_) {}),
        removed.then<void>((_) {}),
        inserted,
      ]);
      expect(await confirmed, isTrue);
      expect(await removed, isTrue);

      final records = await store.load(
        scope: AssistantMemoryScope.project,
        scopeId: 'Ai-orchestrator-riserva',
        confirmedOnly: false,
      );
      expect(records.map((item) => item.recordKey).toSet(),
          {'state.confirm', 'state.new'});
      expect(
        records.singleWhere((item) => item.recordKey == 'state.confirm').status,
        AssistantMemoryStatus.confirmed,
      );
    });

    test('failed write is reported and does not block later writes', () async {
      final store = AssistantDurableMemoryStore(
        persistence: _FailOnceMemoryPersistence(),
      );
      await expectLater(
        store.upsert(_record(recordKey: 'state.failed')),
        throwsStateError,
      );

      await store.upsert(_record(recordKey: 'state.succeeded'));
      final records = await store.load(
        scope: AssistantMemoryScope.project,
        scopeId: 'Ai-orchestrator-riserva',
        confirmedOnly: false,
      );
      expect(records.map((item) => item.recordKey), ['state.succeeded']);
    });
  });
}
