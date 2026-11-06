import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_immutable_step_plan_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_progress_checkpoint_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_resume_preflight.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_semantic_step_evidence_store.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ProtectedBackend implements HybridCloudConsentStorage {
  final entries = <String, String>{};
  @override
  Future<String?> read(String key) async => entries[key];
  @override
  Future<void> write(String key, String value) async {
    entries[key] = value;
  }
  @override
  Future<void> delete(String key) async { entries.remove(key); }
}

void main() {
  test('H49 integrated: 3 Cloud, 4 Local, 3 Cloud verified checkpoints, '
      'reopen without auto-dispatch', () async {
    final backend = _ProtectedBackend();
    var cloudCalls = 0;
    var localCalls = 0;
    HybridProgressCheckpointJournal newJournal() =>
        HybridProgressCheckpointJournal(
          storage: backend,
          authorizeOwnerSession: (owner, session) async =>
              owner == 'synthetic-owner' && session == 'synthetic-chat',
        );
    final steps = List<String>.generate(
        10, (i) => 'Verified synthetic task step ${i + 1}');
    var journal = newJournal();
    await journal.begin(
      ownerId: 'synthetic-owner', sessionId: 'synthetic-chat',
      taskId: 'synthetic-task', totalSteps: steps.length);
    var planStore = HybridImmutableStepPlanStore(
        storage: backend, journal: journal);
    await planStore.save(
      ownerId: 'synthetic-owner', sessionId: 'synthetic-chat',
      taskId: 'synthetic-task', plan: HybridImmutableStepPlan(steps));
    var receipts = HybridSemanticStepEvidenceStore(
        storage: backend, journal: journal);

    HybridResumePreflight preview() => HybridResumePreflight(
      journal: journal,
      loadPlan: (o, s, t) async => (await planStore.load(
          ownerId: o, sessionId: s, taskId: t))?.steps,
      loadEvidence: (o, s, t, n) async => (await receipts.loadCompletedStep(
          ownerId: o, sessionId: s, taskId: t, step: n))?.output,
    );

    for (var i = 0; i < 10; i++) {
      if (i == 3 || i == 7) {
        // Simulate application restart / network interruption. Merely
        // restoring protected records never dispatches to any provider.
        journal = newJournal();
        planStore = HybridImmutableStepPlanStore(
            storage: backend, journal: journal);
        receipts = HybridSemanticStepEvidenceStore(
            storage: backend, journal: journal);
      }
      final before = await preview().inspect(
        ownerId: 'synthetic-owner', sessionId: 'synthetic-chat',
        taskId: 'synthetic-task');
      expect(before.completedSteps, i);
      expect(before.nextInstruction, steps[i]);
      expect(before.verifiedResults.length, i);
      // These counters represent a hypothetical caller. They are NOT real
      // requests; the components must not make any network calls themselves.
      final executor = i < 3 || i >= 7
          ? HybridCheckpointExecutor.cloud
          : HybridCheckpointExecutor.local;
      if (executor == HybridCheckpointExecutor.cloud) {
        cloudCalls++;
      } else {
        localCalls++;
      }
      await receipts.completeVerifiedStep(
        ownerId: 'synthetic-owner', sessionId: 'synthetic-chat',
        taskId: 'synthetic-task', expectedRevision: i,
        executor: executor,
        result: HybridVerifiedStepResult(
          output: 'verified-output-${i + 1}',
          provenance: 'synthetic-validator-${i + 1}',
        ),
      );
    }
    final end = await preview().inspect(
      ownerId: 'synthetic-owner', sessionId: 'synthetic-chat',
      taskId: 'synthetic-task');
    expect(end.isComplete, isTrue);
    expect(end.nextInstruction, isNull);
    expect(end.completedSteps, 10);
    expect(end.verifiedResults, List<String>.generate(
        10, (i) => 'verified-output-${i + 1}'));
    expect(cloudCalls, 6);
    expect(localCalls, 4);
  });
}
