import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_immutable_step_plan_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_local_step_coordinator.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_progress_checkpoint_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_protected_resume_adapter.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_semantic_step_evidence_store.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Store implements HybridCloudConsentStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
  @override
  Future<void> delete(String key) async { values.remove(key); }
}

void main() {
  late _Store storage;
  late HybridProgressCheckpointJournal journal;
  late HybridSemanticStepEvidenceStore evidence;
  late HybridLocalStepCoordinator coordinator;
  var access = true;

  setUp(() async {
    access = true;
    storage = _Store();
    journal = HybridProgressCheckpointJournal(
      storage: storage,
      authorizeOwnerSession: (o, s) async =>
          access && o == 'owner1' && s == 'chat1',
    );
    final plans = HybridImmutableStepPlanStore(
      storage: storage, journal: journal);
    evidence = HybridSemanticStepEvidenceStore(
      storage: storage, journal: journal);
    await journal.begin(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
      totalSteps: 2);
    await plans.save(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
      plan: HybridImmutableStepPlan(['first local', 'second local']));
    coordinator = HybridLocalStepCoordinator(
      resume: HybridProtectedResumeAdapter(
        journal: journal, plans: plans, evidence: evidence),
      journal: journal,
      evidence: evidence,
    );
  });

  Future<HybridProgressCheckpoint> run(
    HybridLocalStepExecutor local, {
    Future<bool> Function(HybridVerifiedStepResult)? validate,
  }) => coordinator.executeOneLocal(
    ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
    executeLocal: local,
    validateResult: validate ?? (result) async => true,
  );

  test('H50 manual LOCAL work advances exactly one step at a time', () async {
    var calls = 0;
    final first = await run((instruction, previous) async {
      calls++;
      expect(instruction, 'first local');
      expect(previous, isEmpty);
      return const HybridVerifiedStepResult(
        output: 'step-1 output', provenance: 'local-validated');
    });
    expect(first.completedSteps, 1);
    expect(first.lastExecutor, HybridCheckpointExecutor.local);
    final second = await run((instruction, previous) async {
      calls++;
      expect(instruction, 'second local');
      expect(previous, ['step-1 output']);
      return const HybridVerifiedStepResult(
        output: 'step-2 output', provenance: 'local-validated');
    });
    expect(second.status, HybridCheckpointStatus.completed);
    expect(calls, 2);
    await expectLater(
      run((_, __) async {
        calls++;
        return const HybridVerifiedStepResult(
          output: 'unexpected', provenance: 'local-validated');
      }),
      throwsStateError);
    expect(calls, 2);
  });

  test('H50 rejected result never advances progress', () async {
    await expectLater(run(
      (_, __) async => const HybridVerifiedStepResult(
        output: 'unverified local output', provenance: 'untrusted'),
      validate: (_) async => false,
    ), throwsStateError);
    expect((await journal.load(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1'))!.completedSteps, 0);
  });

  test('H50 concurrent progress change fences stale LOCAL output', () async {
    await expectLater(run((_, __) async {
      await evidence.completeVerifiedStep(
        ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
        expectedRevision: 0, executor: HybridCheckpointExecutor.local,
        result: const HybridVerifiedStepResult(
          output: 'other winner', provenance: 'local-validated'));
      return const HybridVerifiedStepResult(
        output: 'late result', provenance: 'local-validated');
    }), throwsStateError);
    final result = await evidence.loadCompletedStep(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1', step: 1);
    expect(result?.output, 'other winner');
  });

  test('H50 owner revocation blocks even the LOCAL execution', () async {
    access = false;
    var invoked = false;
    await expectLater(run((_, __) async {
      invoked = true;
      return const HybridVerifiedStepResult(
        output: 'no', provenance: 'local');
    }), throwsStateError);
    expect(invoked, isFalse);
  });
}
