import 'dart:convert';

import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_progress_checkpoint_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_immutable_step_plan_store.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Backend implements HybridCloudConsentStorage {
  final entries = <String, String>{};
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => entries[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('Storage failed');
    entries[key] = value;
  }
  @override
  Future<void> delete(String key) async => entries.remove(key);
}

void main() {
  late _Backend backend;
  late HybridProgressCheckpointJournal journal;
  late HybridImmutableStepPlanStore plans;
  var authorized = true;

  setUp(() async {
    authorized = true;
    backend = _Backend();
    journal = HybridProgressCheckpointJournal(
      storage: backend,
      authorizeOwnerSession: (owner, session) async =>
          authorized && owner == 'owner1' && session == 'chat1',
    );
    plans = HybridImmutableStepPlanStore(storage: backend, journal: journal);
    await journal.begin(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
      totalSteps: 3,
    );
  });

  Future<void> save(List<String> instructions) => plans.save(
    ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
    plan: HybridImmutableStepPlan(instructions),
  );
  Future<HybridImmutableStepPlan?> load() => plans.load(
    ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1');

  test('H49b fixed three-step plan survives process-style recreation', () async {
    await save(['cloud task 1', 'local task 2', 'local task 3']);
    await journal.completeStep(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1',
      expectedRevision: 0, executor: HybridCheckpointExecutor.cloud,
    );
    final afterRestart = HybridImmutableStepPlanStore(
      storage: backend,
      journal: HybridProgressCheckpointJournal(
        storage: backend,
        authorizeOwnerSession: (o, s) async => o == 'owner1' && s == 'chat1',
      ),
    );
    final plan = await afterRestart.load(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'task1');
    expect(plan?.instructionFor(2), 'local task 2');
    expect(plan?.steps.length, 3);
    expect(() => plan!.steps.add('model-injected step'), throwsUnsupportedError);
  });

  test('H49b refuses silent plan changes and step-count mismatch', () async {
    await save(['A', 'B', 'C']);
    await save(['A', 'B', 'C']);
    await expectLater(save(['A', 'forged', 'C']), throwsStateError);
    await expectLater(save(['A', 'B']), throwsStateError);
    expect((await load())?.instructionFor(2), 'B');
  });

  test('H49b corrupted plan and missing integrity key fail closed', () async {
    await save(['A', 'B', 'C']);
    final key = backend.entries.keys.singleWhere(
      (k) => k.startsWith('aivexus.hybrid.plan.h49b.')
          && k != 'aivexus.hybrid.plan.h49b.mac');
    final envelope = jsonDecode(backend.entries[key]!) as Map<String, dynamic>;
    final body = jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
    body['steps'] = ['A', 'evil', 'C'];
    envelope['payload'] = jsonEncode(body);
    backend.entries[key] = jsonEncode(envelope);
    expect(await load(), isNull);
    await expectLater(save(['A', 'B', 'C']), throwsStateError);
    backend.entries.remove('aivexus.hybrid.plan.h49b.mac');
    expect(await load(), isNull);
  });

  test('H49b denies other session and failed storage writes', () async {
    backend.failWrites = true;
    await expectLater(save(['A', 'B', 'C']), throwsStateError);
    backend.failWrites = false;
    expect(await load(), isNull);
    await save(['A', 'B', 'C']);
    authorized = false;
    await expectLater(load(), throwsStateError);
    await expectLater(save(['A', 'B', 'C']), throwsStateError);
    await expectLater(plans.load(
      ownerId: 'owner1', sessionId: 'chat2', taskId: 'task1'),
      throwsStateError);
  });

  test('H49b rejects empty, oversized, or fabricated task plans', () async {
    expect(() => HybridImmutableStepPlan([]), throwsArgumentError);
    expect(() => HybridImmutableStepPlan(['A', '']), throwsArgumentError);
    expect(() => HybridImmutableStepPlan([('A' * 2049)]), throwsArgumentError);
    await expectLater(plans.save(
      ownerId: 'owner1', sessionId: 'chat1', taskId: 'unknown',
      plan: HybridImmutableStepPlan(['A']),
    ), throwsStateError);
  });
}
