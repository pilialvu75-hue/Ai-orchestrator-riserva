import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_attempt_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_snapshot_store.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ProtectedBackend implements HybridProtectedSnapshotBackend {
  final Map<String, String> values = <String, String>{};
  bool failWrite = false;
  bool hideStoredReads = false;
  bool failDelete = false;

  @override
  Future<String?> read(String key) async {
    if (hideStoredReads && values.containsKey(key)) return null;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('OS protected write refused');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('OS protected delete refused');
    values.remove(key);
  }
}

void main() {
  const owner = 'authenticated-test-owner';
  const execution = 'protected-hybrid-task';

  test('the intent is durably readable after save and survives new instances',
      () async {
    final backend = _ProtectedBackend();
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: execution), isNull);

    await journal.markBeforeInference(
      ownerId: owner, executionId: execution, checkpoint: 1,
    );
    final newInstance = HybridCheckpointAttemptJournal(backend: backend);
    expect(await newInstance.pendingCheckpoint(
      ownerId: owner, executionId: execution), 1);

    // Approved same-step retry may re-use an already durable intent without
    // deleting and recreating a false gap in persistent crash protection.
    await newInstance.markBeforeInference(
      ownerId: owner, executionId: execution, checkpoint: 1,
    );
    expect(backend.values, hasLength(1));
    await journal.clearAfterCommit(
      ownerId: owner, executionId: execution, completedCount: 1,
    );
    expect(await newInstance.pendingCheckpoint(
      ownerId: owner, executionId: execution), isNull);
  });

  test('protected write failure cannot create a successful intent',
      () async {
    final backend = _ProtectedBackend()..failWrite = true;
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    await expectLater(
      journal.markBeforeInference(
        ownerId: owner, executionId: execution, checkpoint: 1,
      ),
      throwsStateError,
    );
    expect(backend.values, isEmpty);
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: execution), isNull);
  });

  test('a write without protected readback acknowledgment is rejected',
      () async {
    final backend = _ProtectedBackend()..hideStoredReads = true;
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    await expectLater(
      journal.markBeforeInference(
        ownerId: owner, executionId: execution, checkpoint: 1,
      ),
      throwsStateError,
    );
    // An uncertain write may exist on disk, but model execution MUST NOT be
    // initiated by the caller. If storage recovers it is conservatively seen.
    expect(backend.values, hasLength(1));
    backend.hideStoredReads = false;
    expect(await HybridCheckpointAttemptJournal(backend: backend)
        .pendingCheckpoint(ownerId: owner, executionId: execution), 1);
  });

  test('cannot skip or clear an uncommitted checkpoint', () async {
    final backend = _ProtectedBackend();
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    await journal.markBeforeInference(
      ownerId: owner, executionId: execution, checkpoint: 2,
    );
    await expectLater(
      journal.markBeforeInference(
        ownerId: owner, executionId: execution, checkpoint: 3,
      ),
      throwsStateError,
    );
    await expectLater(
      journal.clearAfterCommit(
        ownerId: owner, executionId: execution, completedCount: 1,
      ),
      throwsStateError,
    );
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: execution), 2);
    await journal.clearAfterCommit(
      ownerId: owner, executionId: execution, completedCount: 2,
    );
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: execution), isNull);
  });

  test('owner and execution are isolated and tampered storage fails closed',
      () async {
    final backend = _ProtectedBackend();
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    await journal.markBeforeInference(
      ownerId: owner, executionId: execution, checkpoint: 1,
    );
    expect(await journal.pendingCheckpoint(
      ownerId: 'different-owner', executionId: execution), isNull);
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: 'another-execution'), isNull);
    final key = backend.values.keys.single;
    backend.values[key] = '{"version":1,"checkpoint":1,"executionId":"spoof"}';
    await expectLater(
      journal.pendingCheckpoint(ownerId: owner, executionId: execution),
      throwsFormatException,
    );
    await expectLater(
      journal.markBeforeInference(
        ownerId: owner, executionId: execution, checkpoint: 1,
      ),
      throwsFormatException,
    );
  });

  test('failed clearance keeps a committed intent visible for safe cleanup',
      () async {
    final backend = _ProtectedBackend();
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    await journal.markBeforeInference(
      ownerId: owner, executionId: execution, checkpoint: 1,
    );
    backend.failDelete = true;
    await expectLater(
      journal.clearAfterCommit(
        ownerId: owner, executionId: execution, completedCount: 1,
      ),
      throwsStateError,
    );
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: execution), 1);
    backend.failDelete = false;
    await journal.clearAfterCommit(
      ownerId: owner, executionId: execution, completedCount: 1,
    );
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: execution), isNull);
  });
}
