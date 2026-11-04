import 'dart:async';
import 'dart:convert';

import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_ledger.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_snapshot_store.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeProtectedBackend implements HybridProtectedSnapshotBackend {
  final Map<String, String> values = <String, String>{};
  bool rejectNextWrite = false;
  bool failReadback = false;
  Completer<void>? pendingWrite;

  @override
  Future<String?> read(String key) async {
    if (failReadback) return null;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (rejectNextWrite) {
      rejectNextWrite = false;
      throw StateError('Secure storage write failed');
    }
    final hold = pendingWrite;
    if (hold != null) await hold.future;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  const owner = 'owner-private-test';

  Future<void> finish(
    HybridCheckpointLedger ledger,
    HybridAttemptLease lease,
    HybridCheckpointSnapshotStore store,
    int expected,
  ) async {
    expect(ledger.startCheckpoint(lease), expected);
    await ledger.completeCheckpointDurably(
      lease: lease,
      checkpoint: expected,
      result: 'Received, verified step $expected',
      persist: (snapshot) => store.saveSnapshot(
        ownerId: owner,
        snapshot: snapshot,
      ),
    );
  }

  test('10-step Cloud to Local handoff survives two process restarts',
      () async {
    final backend = _FakeProtectedBackend();
    var store = HybridCheckpointSnapshotStore(backend: backend);
    var ledger = HybridCheckpointLedger(
      executionId: 'gallery-case',
      totalCheckpoints: 10,
    );
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());

    final cloud = ledger.beginAttempt(
      attemptId: 'cloud-1',
      executor: HybridCheckpointExecutor.cloud,
    );
    for (var n = 1; n <= 3; n++) {
      await finish(ledger, cloud, store, n);
    }

    // New process, with no Cloud lease, now has the first 3 results.
    store = HybridCheckpointSnapshotStore(backend: backend);
    ledger = (await store.load(ownerId: owner, executionId: 'gallery-case'))!;
    expect(ledger.completedCount, 3);
    expect(ledger.inFlightCheckpoint, isNull);
    final local = ledger.beginAttempt(
      attemptId: 'local-2',
      executor: HybridCheckpointExecutor.local,
    );
    for (var n = 4; n <= 7; n++) {
      await finish(ledger, local, store, n);
    }

    // Reconnection does not force an automatic switch to Cloud.
    expect(ledger.nextCheckpoint, 8);
    store = HybridCheckpointSnapshotStore(backend: backend);
    ledger = (await store.load(ownerId: owner, executionId: 'gallery-case'))!;
    final localAfterRestart = ledger.beginAttempt(
      attemptId: 'local-3',
      executor: HybridCheckpointExecutor.local,
    );
    for (var n = 8; n <= 10; n++) {
      await finish(ledger, localAfterRestart, store, n);
    }

    expect(ledger.isComplete, isTrue);
    expect(ledger.completed.map((x) => x.number),
        orderedEquals(List<int>.generate(10, (i) => i + 1)));
    expect(
      ledger.completed
          .where((x) => x.executor == HybridCheckpointExecutor.cloud),
      hasLength(3),
    );
    expect(
      ledger.completed
          .where((x) => x.executor == HybridCheckpointExecutor.local),
      hasLength(7),
    );
    final reopened = (await HybridCheckpointSnapshotStore(backend: backend)
        .load(ownerId: owner, executionId: 'gallery-case'))!;
    expect(reopened.isComplete, isTrue);
  });

  test('a failed protected write never advances in-memory progress',
      () async {
    final backend = _FakeProtectedBackend();
    final store = HybridCheckpointSnapshotStore(backend: backend);
    final ledger =
        HybridCheckpointLedger(executionId: 'failed-write', totalCheckpoints: 2);
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());
    final local = ledger.beginAttempt(
      attemptId: 'local-1',
      executor: HybridCheckpointExecutor.local,
    );
    final step = ledger.startCheckpoint(local);

    backend.rejectNextWrite = true;
    await expectLater(
      ledger.completeCheckpointDurably(
        lease: local,
        checkpoint: step,
        result: 'Result never stored',
        persist: (snapshot) =>
            store.saveSnapshot(ownerId: owner, snapshot: snapshot),
      ),
      throwsStateError,
    );

    expect(ledger.completedCount, 0);
    expect(ledger.inFlightCheckpoint, 1);
    final reopened =
        (await store.load(ownerId: owner, executionId: 'failed-write'))!;
    expect(reopened.completedCount, 0);
    expect(reopened.nextCheckpoint, 1);

    // Retry after protected storage is healthy.
    await ledger.completeCheckpointDurably(
      lease: local,
      checkpoint: step,
      result: 'Result stored on retry',
      persist: (snapshot) =>
          store.saveSnapshot(ownerId: owner, snapshot: snapshot),
    );
    expect(ledger.completedCount, 1);
  });

  test('handoff is blocked while a checkpoint commit is not acknowledged',
      () async {
    final backend = _FakeProtectedBackend();
    final store = HybridCheckpointSnapshotStore(backend: backend);
    final ledger =
        HybridCheckpointLedger(executionId: 'pending-write', totalCheckpoints: 2);
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());
    final local = ledger.beginAttempt(
      attemptId: 'local-1',
      executor: HybridCheckpointExecutor.local,
    );
    final step = ledger.startCheckpoint(local);

    final gate = Completer<void>();
    backend.pendingWrite = gate;
    final committing = ledger.completeCheckpointDurably(
      lease: local,
      checkpoint: step,
      result: 'Wait for secure write',
      persist: (snapshot) =>
          store.saveSnapshot(ownerId: owner, snapshot: snapshot),
    );

    expect(ledger.completedCount, 0);
    expect(() => ledger.interruptAttempt(local), throwsStateError);
    expect(
      () => ledger.beginAttempt(
        attemptId: 'cloud-2',
        executor: HybridCheckpointExecutor.cloud,
      ),
      throwsStateError,
    );
    gate.complete();
    await committing;
    expect(ledger.completedCount, 1);
    ledger.interruptAttempt(local);
    final cloud = ledger.beginAttempt(
      attemptId: 'cloud-2',
      executor: HybridCheckpointExecutor.cloud,
    );
    await finish(ledger, cloud, store, 2);
  });

  test('owner identities are separated; no snapshot reaches the wrong owner',
      () async {
    final backend = _FakeProtectedBackend();
    final store = HybridCheckpointSnapshotStore(backend: backend);
    final ledger =
        HybridCheckpointLedger(executionId: 'private', totalCheckpoints: 1);
    await store.saveSnapshot(ownerId: 'user-A', snapshot: ledger.toJson());

    expect(await store.load(ownerId: 'user-B', executionId: 'private'), isNull);
    expect(
      await store.load(ownerId: 'user-A', executionId: 'private'),
      isNotNull,
    );
    expect(backend.values.keys.single, isNot(contains('user-A')));
    await store.delete(ownerId: 'user-B', executionId: 'private');
    expect(
      await store.load(ownerId: 'user-A', executionId: 'private'),
      isNotNull,
    );
    await store.delete(ownerId: 'user-A', executionId: 'private');
    expect(await store.load(ownerId: 'user-A', executionId: 'private'), isNull);
  });

  test('protected payload is bound to the authenticated owner', () async {
    final backend = _FakeProtectedBackend();
    final store = HybridCheckpointSnapshotStore(backend: backend);
    final ledger = HybridCheckpointLedger(
      executionId: 'owner-binding',
      totalCheckpoints: 1,
    );
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());

    // Simulates a bad backup or corrupted secure-store entry associated with
    // the correct key but the wrong owner fingerprint.
    final key = backend.values.keys.single;
    final envelope = jsonDecode(backend.values[key]!)
        as Map<String, dynamic>;
    envelope['ownerFingerprint'] = 'different-owner';
    backend.values[key] = jsonEncode(envelope);

    await expectLater(
      store.load(ownerId: owner, executionId: 'owner-binding'),
      throwsFormatException,
    );
  });

  test('out-of-order, rewritten and stale snapshots fail closed', () async {
    final backend = _FakeProtectedBackend();
    final store = HybridCheckpointSnapshotStore(backend: backend);
    final ledger =
        HybridCheckpointLedger(executionId: 'monotonic', totalCheckpoints: 3);
    final initial = ledger.toJson();
    await store.saveSnapshot(ownerId: owner, snapshot: initial);
    final cloud = ledger.beginAttempt(
      attemptId: 'cloud-1',
      executor: HybridCheckpointExecutor.cloud,
    );
    await finish(ledger, cloud, store, 1);

    // A stale background writer cannot erase step 1.
    await expectLater(
      store.saveSnapshot(ownerId: owner, snapshot: initial),
      throwsStateError,
    );

    final rewritten = jsonDecode(jsonEncode(ledger.toJson()))
        as Map<String, dynamic>;
    final steps = rewritten['completed'] as List<dynamic>;
    (steps.first as Map<String, dynamic>)['result'] = 'tampered';
    await expectLater(
      store.saveSnapshot(
        ownerId: owner,
        snapshot: Map<String, Object?>.from(rewritten),
      ),
      throwsStateError,
    );
    expect((await store.load(ownerId: owner, executionId: 'monotonic'))!
        .completed.single.result, 'Received, verified step 1');
  });

  test('oversized results do not complete a checkpoint or enter the store',
      () async {
    final backend = _FakeProtectedBackend();
    final store = HybridCheckpointSnapshotStore(backend: backend);
    final ledger =
        HybridCheckpointLedger(executionId: 'large', totalCheckpoints: 2);
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());
    final cloud = ledger.beginAttempt(
      attemptId: 'cloud-1',
      executor: HybridCheckpointExecutor.cloud,
    );
    ledger.startCheckpoint(cloud);

    await expectLater(
      ledger.completeCheckpointDurably(
        lease: cloud,
        checkpoint: 1,
        result: 'x' * (HybridCheckpointSnapshotStore.maxSnapshotBytes + 1),
        persist: (snapshot) =>
            store.saveSnapshot(ownerId: owner, snapshot: snapshot),
      ),
      throwsStateError,
    );
    expect(ledger.completedCount, 0);
    expect((await store.load(ownerId: owner, executionId: 'large'))!
        .completedCount, 0);
  });
}
