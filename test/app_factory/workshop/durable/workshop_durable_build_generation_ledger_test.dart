import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_generation_ledger.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_source_snapshot.dart';

void main() {
  test('first reservation survives restart and blocks accidental redispatch',
      () async {
    final store = _InMemoryGenerationStorage();
    final first = WorkshopDurableBuildGenerationLedger(storage: store);
    final request = _request('demo', 'ui-1');
    final frozenSource = _snapshot('void main() {}');

    final ticket = await first.reserveNew(
      request: request,
      source: frozenSource,
    );
    expect(ticket.generation, 1);
    expect(ticket.state, WorkshopDurableGenerationState.active);
    expect(ticket.buildId, startsWith('durable-v2-'));

    final reopened = WorkshopDurableBuildGenerationLedger(storage: store);
    final recovered = await reopened.recoverLatest(_request('demo', 'ui-2'));
    expect(recovered?.buildId, ticket.buildId);
    expect(recovered?.sourceSha256, ticket.sourceSha256);

    await expectLater(
      reopened.reserveNew(
        request: _request('demo', 'ui-3'),
        source: frozenSource,
      ),
      throwsStateError,
    );
  });

  test('terminal outcome allows new generation even on identical source',
      () async {
    final store = _InMemoryGenerationStorage();
    final ledger = WorkshopDurableBuildGenerationLedger(storage: store);
    final request = _request('demo', 'ui-1');
    final source = _snapshot('void main() {}');
    final first = await ledger.reserveNew(request: request, source: source);
    final terminal = await ledger.markTerminal(
      request: _request('demo', 'ui-2'),
      expectedBuildId: first.buildId,
      succeeded: false,
    );
    expect(terminal.state, WorkshopDurableGenerationState.failed);

    final second = await ledger.reserveNew(
      request: _request('demo', 'ui-3'),
      source: source,
    );
    expect(second.generation, 2);
    expect(second.buildId, isNot(first.buildId));
    expect(second.sourceSha256, first.sourceSha256);

    final recovered = await WorkshopDurableBuildGenerationLedger(
      storage: store,
    ).recoverLatest(_request('demo', 'ui-4'));
    expect(recovered?.generation, 2);
    expect(recovered?.state, WorkshopDurableGenerationState.active);
  });

  test('stale terminal completion never overwrites a later active generation',
      () async {
    final store = _InMemoryGenerationStorage();
    final ledger = WorkshopDurableBuildGenerationLedger(storage: store);
    final req = _request('demo', 'first');
    final first = await ledger.reserveNew(
      request: req,
      source: _snapshot('original source'),
    );
    await ledger.markTerminal(
      request: req,
      expectedBuildId: first.buildId,
      succeeded: true,
    );
    final current = await ledger.reserveNew(
      request: _request('demo', 'second'),
      source: _snapshot('changed source'),
    );
    expect(current.generation, 2);
    expect(current.sourceSha256, isNot(first.sourceSha256));

    await expectLater(
      ledger.markTerminal(
        request: req,
        expectedBuildId: first.buildId,
        succeeded: false,
      ),
      throwsStateError,
    );
    expect((await ledger.recoverLatest(req))?.buildId, current.buildId);
    expect((await ledger.recoverLatest(req))?.state,
        WorkshopDurableGenerationState.active);
  });

  test('terminal transition is idempotent but conflicting status is rejected',
      () async {
    final store = _InMemoryGenerationStorage();
    final ledger = WorkshopDurableBuildGenerationLedger(storage: store);
    final request = _request('demo', 'ui');
    final reserved = await ledger.reserveNew(
      request: request,
      source: _snapshot('source'),
    );
    final first = await ledger.markTerminal(
      request: request,
      expectedBuildId: reserved.buildId,
      succeeded: true,
    );
    final replay = await ledger.markTerminal(
      request: request,
      expectedBuildId: reserved.buildId,
      succeeded: true,
    );
    expect(replay.buildId, first.buildId);
    await expectLater(
      ledger.markTerminal(
        request: request,
        expectedBuildId: reserved.buildId,
        succeeded: false,
      ),
      throwsStateError,
    );
  });

  test('concurrent instances preserve reservations for different intents',
      () async {
    final store = _InMemoryGenerationStorage();
    final first = WorkshopDurableBuildGenerationLedger(storage: store);
    final second = WorkshopDurableBuildGenerationLedger(storage: store);
    final results = await Future.wait(<Future<WorkshopDurableBuildReservation>>[
      first.reserveNew(
        request: _request('a', 'ui-a'),
        source: _snapshot('a'),
      ),
      second.reserveNew(
        request: _request('b', 'ui-b'),
        source: _snapshot('b'),
      ),
    ]);
    expect(results.map((r) => r.buildId).toSet().length, 2);
    expect(await first.recoverLatest(_request('a', 'reopen')), isNotNull);
    expect(await second.recoverLatest(_request('b', 'reopen')), isNotNull);
  });

  test('corrupted journal refuses allocation and retains original bytes',
      () async {
    final store = _InMemoryGenerationStorage();
    store.raw = '{invalid';
    final ledger = WorkshopDurableBuildGenerationLedger(storage: store);
    await expectLater(
      ledger.reserveNew(
        request: _request('demo', 'ui'),
        source: _snapshot('source'),
      ),
      throwsStateError,
    );
    expect(store.raw, '{invalid');
  });

  test('platform write rejected cannot be mistaken for a reservation',
      () async {
    final store = _InMemoryGenerationStorage()..rejectWrites = true;
    final ledger = WorkshopDurableBuildGenerationLedger(storage: store);
    final request = _request('demo', 'ui-rejected');
    await expectLater(
      ledger.reserveNew(request: request, source: _snapshot('source')),
      throwsStateError,
    );
    expect(store.raw, isNull);
    store.rejectWrites = false;
    expect(await ledger.recoverLatest(_request('demo', 'ui-after-restart')),
        isNull);
    final valid = await ledger.reserveNew(
      request: request,
      source: _snapshot('source'),
    );
    expect(valid.generation, 1);
  });

  test('false-positive write acknowledgement fails readback gate',
      () async {
    final store = _InMemoryGenerationStorage()..ackWithoutPersist = true;
    final ledger = WorkshopDurableBuildGenerationLedger(storage: store);
    await expectLater(
      ledger.reserveNew(
        request: _request('demo', 'ui'),
        source: _snapshot('source'),
      ),
      throwsStateError,
    );
    expect(store.raw, isNull);
  });

  test('journal persists only hashes, counters and states, never source',
      () async {
    final store = _InMemoryGenerationStorage();
    final ledger = WorkshopDurableBuildGenerationLedger(storage: store);
    await ledger.reserveNew(
      request: _request('private-project', 'ui-1'),
      source: _snapshot('PRIVATE CODE / DO NOT UPLOAD'),
    );
    final raw = store.raw!;
    expect(jsonDecode(raw), isA<Map>());
    expect(raw, isNot(contains('private-project')));
    expect(raw, isNot(contains('/workspace/')));
    expect(raw, isNot(contains('PRIVATE CODE')));
  });
}

WorkshopBuildRequest _request(String project, String id) => WorkshopBuildRequest(
      id: id,
      projectId: project,
      projectPath: '/workspace/' + project,
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.remote,
    );

WorkshopBuildSourceSnapshot _snapshot(String text) {
  final bytes = Uint8List.fromList(utf8.encode(text));
  return WorkshopBuildSourceSnapshot(
    rootPath: '/workspace/demo',
    files: <WorkshopBuildSourceFile>[
      WorkshopBuildSourceFile(relativePath: 'lib/main.dart', bytes: bytes),
    ],
    totalBytes: bytes.lengthInBytes,
  );
}

final class _InMemoryGenerationStorage
    implements WorkshopDurableGenerationStorage {
  String? raw;
  bool rejectWrites = false;
  bool ackWithoutPersist = false;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String value) async {
    if (rejectWrites) return false;
    if (!ackWithoutPersist) raw = value;
    return true;
  }
}
