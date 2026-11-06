import 'dart:convert';

import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_progress_checkpoint_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_semantic_step_evidence_store.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ProtectedStorage implements HybridCloudConsentStorage {
  final entries = <String, String>{};
  bool rejectWrites = false;

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async {
    if (rejectWrites) throw StateError('secure storage unavailable');
    entries[key] = value;
  }

  @override
  Future<void> delete(String key) async => entries.remove(key);
}

void main() {
  late _ProtectedStorage storage;
  late HybridProgressCheckpointJournal journal;
  late HybridSemanticStepEvidenceStore evidence;
  var access = true;

  setUp(() async {
    access = true;
    storage = _ProtectedStorage();
    journal = HybridProgressCheckpointJournal(
      storage: storage,
      authorizeOwnerSession: (owner, session) async =>
          access && owner == 'owner1' && session == 'chat1',
    );
    evidence = HybridSemanticStepEvidenceStore(
      storage: storage, journal: journal);
    await journal.begin(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
      totalSteps: 3,
    );
  });

  Future<HybridProgressCheckpoint> step(int revision,
      HybridCheckpointExecutor executor, String value) =>
      evidence.completeVerifiedStep(
        ownerId: 'owner1',
        sessionId: 'chat1',
        taskId: 'task1',
        expectedRevision: revision,
        executor: executor,
        result: HybridVerifiedStepResult(
          output: value,
          provenance: 'synthetic verified stage $revision',
        ),
      );

  Future<HybridVerifiedStepResult?> read(int index) =>
      evidence.loadCompletedStep(
        ownerId: 'owner1', sessionId: 'chat1',
        taskId: 'task1', step: index);

  test('H49a checkpoint 1-3 Cloud/Local results survive fresh instances',
      () async {
    await step(0, HybridCheckpointExecutor.cloud, 'verified A');
    await step(1, HybridCheckpointExecutor.local, 'verified B');
    final reloaded = HybridSemanticStepEvidenceStore(
      storage: storage,
      journal: HybridProgressCheckpointJournal(
        storage: storage,
        authorizeOwnerSession: (o, s) async =>
            o == 'owner1' && s == 'chat1',
      ),
    );
    final second = await reloaded.loadCompletedStep(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1', step: 2,
    );
    expect(second?.output, 'verified B');
    expect((await read(1))?.output, 'verified A');
    expect(await read(3), isNull);
    await step(2, HybridCheckpointExecutor.local, 'verified C');
    expect((await read(3))?.output, 'verified C');
    await expectLater(
      step(3, HybridCheckpointExecutor.cloud, 'duplicate'),
      throwsStateError);
  });

  test('H49a failed protected write cannot advance H48 counter', () async {
    storage.rejectWrites = true;
    await expectLater(
      step(0, HybridCheckpointExecutor.local, 'not committed'),
      throwsStateError);
    final checkpoint = await journal.load(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1');
    expect(checkpoint!.completedSteps, 0);
    expect(await read(1), isNull);
  });

  test('H49a progress revision rejects replay, missing and stale steps',
      () async {
    await step(0, HybridCheckpointExecutor.cloud, 'completed');
    await expectLater(
      step(0, HybridCheckpointExecutor.local, 'repeat'),
      throwsStateError);
    expect(await read(2), isNull);
  });

  test('H49a HMAC corruption and access revocation fail closed', () async {
    await step(0, HybridCheckpointExecutor.local, 'verified');
    final key = storage.entries.keys.singleWhere(
      (k) => k.startsWith('aivexus.hybrid.semantic.h49a.')
        && k != 'aivexus.hybrid.semantic.h49a.mac',
    );
    final envelope = jsonDecode(storage.entries[key]!)
        as Map<String, dynamic>;
    final payload = jsonDecode(envelope['payload'] as String)
        as Map<String, dynamic>;
    payload['output'] = 'forged result';
    envelope['payload'] = jsonEncode(payload);
    storage.entries[key] = jsonEncode(envelope);
    expect(await read(1), isNull);
    access = false;
    await expectLater(read(1), throwsStateError);
  });

  test('H49a non-received results and missing provenance cannot commit',
      () async {
    await expectLater(
      step(0, HybridCheckpointExecutor.cloud, ''),
      throwsArgumentError);
    await expectLater(
      evidence.completeVerifiedStep(
        ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
        expectedRevision: 0, executor: HybridCheckpointExecutor.cloud,
        result: const HybridVerifiedStepResult(
          output: 'unverified', provenance: ''),
      ),
      throwsArgumentError);
    expect((await journal.load(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1'))!.completedSteps, 0);
  });
}
