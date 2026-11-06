import 'dart:convert';

import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_immutable_step_plan_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_progress_checkpoint_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_protected_resume_adapter.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_semantic_step_evidence_store.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ProtectedStorage implements HybridCloudConsentStorage {
  final Map<String, String> data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async { data[key] = value; }
  @override
  Future<void> delete(String key) async { data.remove(key); }
}

void main() {
  late _ProtectedStorage storage;
  late HybridProgressCheckpointJournal journal;
  late HybridImmutableStepPlanStore plans;
  late HybridSemanticStepEvidenceStore evidence;
  late HybridProtectedResumeAdapter adapter;
  var authorized = true;

  setUp(() async {
    authorized = true;
    storage = _ProtectedStorage();
    journal = HybridProgressCheckpointJournal(
      storage: storage,
      authorizeOwnerSession: (owner, session) async =>
          authorized && owner == 'owner1' && session == 'chat1',
    );
    plans = HybridImmutableStepPlanStore(storage: storage, journal: journal);
    evidence = HybridSemanticStepEvidenceStore(storage: storage, journal: journal);
    adapter = HybridProtectedResumeAdapter(
      journal: journal, plans: plans, evidence: evidence);
    await journal.begin(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1', totalSteps: 2);
    await plans.save(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
      plan: HybridImmutableStepPlan(['first instruction', 'second instruction']));
  });

  Future<void> finishOne() async {
    await evidence.completeVerifiedStep(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
      expectedRevision: 0, executor: HybridCheckpointExecutor.cloud,
      result: const HybridVerifiedStepResult(
        output: 'verified answer', provenance: 'verified synthetic source'),
    );
  }

  test('H49d reads protected results and next instruction after restart',
      () async {
    await finishOne();
    final reopened = HybridProgressCheckpointJournal(
      storage: storage,
      authorizeOwnerSession: (o, s) async => o == 'owner1' && s == 'chat1',
    );
    final view = await HybridProtectedResumeAdapter(
      journal: reopened,
      plans: HybridImmutableStepPlanStore(storage: storage, journal: reopened),
      evidence: HybridSemanticStepEvidenceStore(storage: storage, journal: reopened),
    ).inspect(ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1');
    expect(view.completedSteps, 1);
    expect(view.verifiedResults, ['verified answer']);
    expect(view.nextInstruction, 'second instruction');
  });

  test('H49d damaged evidence rejects resume instead of guessing', () async {
    await finishOne();
    final receiptKey = storage.data.keys.singleWhere((key) =>
        key.startsWith('aivexus.hybrid.semantic.h49a.') &&
        key != 'aivexus.hybrid.semantic.h49a.mac');
    final envelope = jsonDecode(storage.data[receiptKey]!)
        as Map<String, dynamic>;
    final payload = jsonDecode(envelope['payload'] as String)
        as Map<String, dynamic>;
    payload['provenance'] = 'forged provenance';
    envelope['payload'] = jsonEncode(payload);
    storage.data[receiptKey] = jsonEncode(envelope);
    await expectLater(adapter.inspect(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1'),
      throwsStateError);
  });

  test('H49d revocation and incorrect session deny access', () async {
    await finishOne();
    authorized = false;
    await expectLater(adapter.inspect(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1'),
      throwsStateError);
    await expectLater(adapter.inspect(
      ownerId: 'owner1', sessionId: 'another-chat', taskId: 'task1'),
      throwsStateError);
  });

  test('H49d has no implicit inference and no Cloud authorization', () async {
    final view = await adapter.inspect(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1');
    expect(view.completedSteps, 0);
    expect(view.nextInstruction, 'first instruction');
    expect(view.verifiedResults, isEmpty);
  });
}
