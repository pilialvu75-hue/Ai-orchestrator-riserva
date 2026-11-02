import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_execution_coordinator.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_ledger.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_plan_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_snapshot_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_step_runner.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ProtectedBackend implements HybridProtectedSnapshotBackend {
  final Map<String, String> values = {};
  bool failNextWrite = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('OS secure write failed');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

CloudRuntimeProvider _provider() => CloudRuntimeProvider(
      sendQuery: (String provider, AiRequest request) async => AiResponse(
        text: 'Unused API mock',
        model: 'unused',
        tokensUsed: 0,
        timestamp: 0,
      ),
      supportedProviders: () => const ['gemini'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([provider]) => provider ?? 'gemini',
      automaticUseAllowedForTask: (_, __) => true,
    );

HybridCheckpointExecutionCoordinator _coordinator(
  _ProtectedBackend backend,
  List<InferenceRequest> calls,
) {
  final snapshots = HybridCheckpointSnapshotStore(backend: backend);
  return HybridCheckpointExecutionCoordinator(
    planStore: HybridCheckpointPlanStore(backend: backend),
    snapshotStore: snapshots,
    stepRunner: HybridCheckpointStepRunner(
      snapshotStore: snapshots,
      cloudRuntimeProvider: _provider(),
      streamInference: (request) async* {
        calls.add(request);
        yield InferenceResponse.finalChunk(
          text: 'Completed: ${request.checkpointId}',
          tokensGenerated: 3,
          providerId: request.cloudProviderId,
          model: 'synthetic',
        );
      },
    ),
  );
}

void main() {
  const owner = 'owner-A';
  final instructions =
      List<String>.generate(10, (i) => 'Calcola e verifica passo ${i + 1}');

  Future<void> next(
    HybridCheckpointExecutionCoordinator coordinator,
    HybridResumableExecution execution,
    HybridAttemptLease lease, {
    required bool offline,
  }) async {
    final expected = execution.nextCheckpoint;
    final result = await coordinator.executeNext(
      ownerId: owner,
      execution: execution,
      lease: lease,
      sessionId: 'gallery-session',
      isOffline: offline,
      validateResult: (r) async => r == 'Completed: checkpoint-$expected',
      authorizeCloudText: (_) async => true,
    );
    expect(result, 'Completed: checkpoint-$expected');
  }

  test('immutable plan and progress resume together from step 8 after restart',
      () async {
    final backend = _ProtectedBackend();
    final requests = <InferenceRequest>[];
    var coordinator = _coordinator(backend, requests);
    final plan = HybridCheckpointPlan(
      executionId: 'gallery-10',
      instructions: instructions,
    );
    var work = await coordinator.create(ownerId: owner, plan: plan);
    final cloud = work.ledger.beginAttempt(
      attemptId: 'cloud-a',
      executor: HybridCheckpointExecutor.cloud,
    );
    for (var step = 1; step <= 3; step++) {
      await next(coordinator, work, cloud, offline: false);
    }
    expect(work.nextCheckpoint, 4);

    // Loss of network, simulated app restart: no Cloud retry is performed.
    coordinator = _coordinator(backend, requests);
    work = (await coordinator.resume(
      ownerId: owner, executionId: 'gallery-10'))!;
    final local = work.ledger.beginAttempt(
      attemptId: 'local-b',
      executor: HybridCheckpointExecutor.local,
    );
    for (var step = 4; step <= 7; step++) {
      await next(coordinator, work, local, offline: true);
    }
    expect(work.nextCheckpoint, 8);

    // Online again, but Local keeps ownership at the user's preferred policy.
    coordinator = _coordinator(backend, requests);
    work = (await coordinator.resume(
      ownerId: owner, executionId: 'gallery-10'))!;
    final continuingLocal = work.ledger.beginAttempt(
      attemptId: 'local-c',
      executor: HybridCheckpointExecutor.local,
    );
    for (var step = 8; step <= 10; step++) {
      await next(coordinator, work, continuingLocal, offline: false);
    }
    expect(work.isComplete, isTrue);
    expect(requests, hasLength(10));
    expect(requests.take(3).every(
        (r) => r.routeDirective == InferenceRouteDirective.cloudOnly), isTrue);
    expect(requests.skip(3).every(
        (r) => r.routeDirective == InferenceRouteDirective.localOnly), isTrue);
    for (var i = 0; i < 10; i++) {
      expect(requests[i].prompt, contains('Current step: ${instructions[i]}'));
    }
    expect(requests[7].prompt, contains('Checkpoint 7 completed by local'));
  });

  test('plan cannot be replaced by Cloud on reconnect', () async {
    final backend = _ProtectedBackend();
    final plans = HybridCheckpointPlanStore(backend: backend);
    final first = HybridCheckpointPlan(
      executionId: 'same-execution',
      instructions: ['Verify evidence A', 'Verify evidence B'],
    );
    await plans.save(ownerId: owner, plan: first);
    await plans.save(ownerId: owner, plan: first); // exact retry is safe

    await expectLater(
      plans.save(
        ownerId: owner,
        plan: HybridCheckpointPlan(
          executionId: 'same-execution',
          instructions: ['Maliciously changed plan', 'Delete all evidence'],
        ),
      ),
      throwsStateError,
    );
    final restored = (await HybridCheckpointPlanStore(backend: backend)
        .load(ownerId: owner, executionId: 'same-execution'))!;
    expect(restored.instructions, ['Verify evidence A', 'Verify evidence B']);
  });

  test('owner mismatch and corrupted plan fail closed', () async {
    final backend = _ProtectedBackend();
    final plans = HybridCheckpointPlanStore(backend: backend);
    await plans.save(
      ownerId: owner,
      plan: HybridCheckpointPlan(
        executionId: 'private-plan',
        instructions: ['Private user instruction'],
      ),
    );
    expect(await plans.load(
      ownerId: 'owner-B', executionId: 'private-plan'), isNull);
    final key = backend.values.keys.single;
    final payload = jsonDecode(backend.values[key]!) as Map<String, dynamic>;
    payload['ownerFingerprint'] = 'invalid-owner';
    backend.values[key] = jsonEncode(payload);

    await expectLater(
      plans.load(ownerId: owner, executionId: 'private-plan'),
      throwsFormatException,
    );
  });

  test('half-registered execution is never invented or auto-executed',
      () async {
    final backend = _ProtectedBackend();
    final plan = HybridCheckpointPlan(
      executionId: 'half-created',
      instructions: ['First checkpoint'],
    );
    await HybridCheckpointPlanStore(backend: backend).save(
      ownerId: owner, plan: plan);
    final calls = <InferenceRequest>[];
    var coordinator = _coordinator(backend, calls);
    await expectLater(
      coordinator.resume(ownerId: owner, executionId: plan.executionId),
      throwsStateError,
    );
    expect(calls, isEmpty);
    // Re-registration of the exact immutable plan can safely complete setup.
    final created = await coordinator.create(ownerId: owner, plan: plan);
    expect(created.nextCheckpoint, 1);
    expect((await coordinator.resume(
      ownerId: owner, executionId: plan.executionId))!.nextCheckpoint, 1);
  });

  test('plan and saved checkpoint count must agree', () async {
    final backend = _ProtectedBackend();
    const executionId = 'different-plan-size';
    final plan = HybridCheckpointPlan(
      executionId: executionId,
      instructions: ['Step 1', 'Step 2'],
    );
    await HybridCheckpointPlanStore(backend: backend)
        .save(ownerId: owner, plan: plan);
    final wrong = HybridCheckpointLedger(
      executionId: executionId,
      totalCheckpoints: 3,
    );
    await HybridCheckpointSnapshotStore(backend: backend)
        .saveSnapshot(ownerId: owner, snapshot: wrong.toJson());

    await expectLater(
      _coordinator(backend, <InferenceRequest>[])
          .resume(ownerId: owner, executionId: executionId),
      throwsStateError,
    );
  });

  test('bounded plan instructions reject empty or giant payloads', () async {
    expect(() => HybridCheckpointPlan(
      executionId: 'invalid',
      instructions: const ['   '],
    ), throwsArgumentError);
    final plan = HybridCheckpointPlan(
      executionId: 'giant',
      instructions: ['x' * (HybridCheckpointPlanStore.maxPlanBytes + 1)],
    );
    final store = HybridCheckpointPlanStore(backend: _ProtectedBackend());
    await expectLater(
      store.save(ownerId: owner, plan: plan),
      throwsStateError,
    );
  });
}
