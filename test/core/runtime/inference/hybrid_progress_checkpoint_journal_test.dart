import 'dart:convert';

import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_progress_checkpoint_journal.dart';
import 'package:flutter_test/flutter_test.dart';

final class _CheckpointProtectedBackend implements HybridCloudConsentStorage {
  final Map<String, String> entries = <String, String>{};
  bool rejectWrites = false;

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async {
    if (rejectWrites) {
      throw StateError('OS-secure storage unavailable');
    }
    entries[key] = value;
  }

  @override
  Future<void> delete(String key) async => entries.remove(key);
}

void main() {
  late _CheckpointProtectedBackend backend;
  var authorized = true;
  DateTime clock = DateTime.utc(2026, 11, 6, 12);

  HybridProgressCheckpointJournal journal() => HybridProgressCheckpointJournal(
        storage: backend,
        now: () => clock,
        authorizeOwnerSession: (owner, session) async =>
            authorized && owner == 'owner1' && session == 'chat1',
      );

  setUp(() {
    backend = _CheckpointProtectedBackend();
    authorized = true;
    clock = DateTime.utc(2026, 11, 6, 12);
  });

  test('H48 local -> Cloud -> local progress survives app restart, '
      'but never resumes automatically', () async {
    final first = journal();
    final started = await first.begin(
      ownerId: 'owner1',
      sessionId: 'chat1',
      taskId: 'task1',
      totalSteps: 3,
    );
    expect(started.completedSteps, 0);
    expect(started.revision, 0);
    expect(started.status, HybridCheckpointStatus.paused);
    expect(started.canContinue, isTrue);

    final local = await first.completeStep(
      ownerId: 'owner1',
      sessionId: 'chat1',
      taskId: 'task1',
      expectedRevision: 0,
      executor: HybridCheckpointExecutor.local,
    );
    expect(local.completedSteps, 1);
    expect(local.lastExecutor, HybridCheckpointExecutor.local);

    clock = clock.add(const Duration(hours: 1));
    // A newly constructed journal represents a restarted application.
    // Reading it must not trigger any LOCAL or CLOUD inference.
    final reopened = journal();
    final checkpoint = await reopened.load(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
    );
    expect(checkpoint, isNotNull);
    expect(checkpoint!.completedSteps, 1);
    expect(checkpoint.revision, 1);
    expect(checkpoint.status, HybridCheckpointStatus.paused);
    expect(checkpoint.updatedAt, local.updatedAt);

    final remote = await reopened.completeStep(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
      expectedRevision: 1,
      executor: HybridCheckpointExecutor.cloud,
    );
    expect(remote.completedSteps, 2);
    expect(remote.lastExecutor, HybridCheckpointExecutor.cloud);
    expect(remote.status, HybridCheckpointStatus.paused);

    final finalRecord = await reopened.completeStep(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
      expectedRevision: 2,
      executor: HybridCheckpointExecutor.local,
    );
    expect(finalRecord.completedSteps, 3);
    expect(finalRecord.status, HybridCheckpointStatus.completed);
    expect(finalRecord.canContinue, isFalse);
    await expectLater(
      reopened.completeStep(
        ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
        expectedRevision: 3, executor: HybridCheckpointExecutor.cloud,
      ),
      throwsStateError,
    );
    // Only HMAC and metadata are stored; no prompt, output or credential.
    final stored = backend.entries.values.join(' ');
    expect(stored, isNot(contains('LOCAL PRIVATE MEMORY')));
    expect(stored, isNot(contains('synthetic-api-key')));
    expect(stored, isNot(contains('Cloud restored')));
    expect(stored, isNot(contains('userPrompt')));
    expect(stored, isNot(contains('outboundText')));
    expect(stored, isNot(contains('accountId')));
  });

  test('H48 cross-session access is denied; opaque ID keys are isolated',
      () async {
    final store = journal();
    await store.begin(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1', totalSteps: 4,
    );
    expect(await store.load(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'other-task',
    ), isNull);
    authorized = false;
    await expectLater(store.load(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
    ), throwsStateError);
    await expectLater(store.remove(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
    ), throwsStateError);
    await expectLater(store.load(
      ownerId: 'owner1', sessionId: 'other-chat', taskId: 'task1',
    ), throwsStateError);
    expect(backend.entries.length, 2);
  });

  test('H48 forged progress / removed integrity key always fails closed',
      () async {
    final store = journal();
    await store.begin(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1', totalSteps: 5,
    );
    final recordKey = backend.entries.keys.singleWhere(
      (key) => key.startsWith('aivexus.hybrid.progress.v1.'),
    );
    final envelope = jsonDecode(backend.entries[recordKey]!)
        as Map<String, dynamic>;
    final payload = jsonDecode(envelope['payload'] as String)
        as Map<String, dynamic>;
    payload['completed'] = 5;
    envelope['payload'] = jsonEncode(payload);
    // Attack/corruption does not have the protected HMAC key.
    backend.entries[recordKey] = jsonEncode(envelope);
    expect(await store.load(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
    ), isNull);
    await expectLater(store.completeStep(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
      expectedRevision: 0, executor: HybridCheckpointExecutor.local,
    ), throwsStateError);
    await expectLater(store.begin(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1', totalSteps: 5,
    ), throwsStateError);
    backend.entries.remove('aivexus.hybrid.progress.hmac.v1');
    expect(await store.load(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
    ), isNull);
  });

  test('H48 duplicate concurrent step cannot overcount or skip revision',
      () async {
    final store = journal();
    await store.begin(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1', totalSteps: 3,
    );
    final calls = await Future.wait(
      <Future<HybridProgressCheckpoint?>>[
        store.completeStep(
          ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
          expectedRevision: 0, executor: HybridCheckpointExecutor.local,
        ).then<HybridProgressCheckpoint?>((entry) => entry)
            .catchError((Object _) => null),
        store.completeStep(
          ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
          expectedRevision: 0, executor: HybridCheckpointExecutor.cloud,
        ).then<HybridProgressCheckpoint?>((entry) => entry)
            .catchError((Object _) => null),
      ],
    );
    expect(calls.whereType<HybridProgressCheckpoint>(), hasLength(1));
    final result = await store.load(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
    );
    expect(result!.completedSteps, 1);
    expect(result.revision, 1);
    await expectLater(store.completeStep(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
      expectedRevision: 0, executor: HybridCheckpointExecutor.local,
    ), throwsStateError);
  });

  test('H48 OS-protected storage failure cannot fabricate a checkpoint',
      () async {
    final store = journal();
    backend.rejectWrites = true;
    await expectLater(store.begin(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1', totalSteps: 2,
    ), throwsStateError);
    expect(backend.entries, isEmpty);
    backend.rejectWrites = false;
    expect(await store.load(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
    ), isNull);
  });

  test('H48 rejects non-opaque ids and impossible step counts', () async {
    final store = journal();
    await expectLater(store.begin(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'Full private prompt must never be used as an ID',
      totalSteps: 2,
    ), throwsArgumentError);
    await expectLater(store.begin(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1', totalSteps: 0,
    ), throwsArgumentError);
    await expectLater(store.begin(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1', totalSteps: 1001,
    ), throwsArgumentError);
    expect(backend.entries, isEmpty);
  });
}
