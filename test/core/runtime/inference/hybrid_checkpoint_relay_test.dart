import 'dart:io';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_execution_coordinator.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_ledger.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_plan_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_relay.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_snapshot_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_step_runner.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Backend implements HybridProtectedSnapshotBackend {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

CloudRuntimeProvider _cloud() => CloudRuntimeProvider(
      sendQuery: (String provider, AiRequest request) async => AiResponse(
        text: 'unused',
        model: 'test',
        tokensUsed: 0,
        timestamp: 0,
      ),
      supportedProviders: () => const ['gemini'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([provider]) => provider ?? 'gemini',
      automaticUseAllowedForTask: (_, __) => true,
    );

HybridCheckpointExecutionCoordinator _coordinator(
  _Backend backend,
  Stream<InferenceResponse> Function(InferenceRequest request) infer,
) {
  final snapshots = HybridCheckpointSnapshotStore(backend: backend);
  return HybridCheckpointExecutionCoordinator(
    planStore: HybridCheckpointPlanStore(backend: backend),
    snapshotStore: snapshots,
    stepRunner: HybridCheckpointStepRunner(
      snapshotStore: snapshots,
      cloudRuntimeProvider: _cloud(),
      streamInference: infer,
    ),
  );
}

void main() {
  const owner = 'tester';
  const session = 'hybrid-relay';

  Future<void> register(
    HybridCheckpointExecutionCoordinator coordinator, {
    int steps = 10,
  }) async {
    await coordinator.create(
      ownerId: owner,
      plan: HybridCheckpointPlan(
        executionId: 'gallery',
        instructions: List<String>.generate(
          steps,
          (index) => 'Validate step ${index + 1}',
        ),
      ),
    );
  }

  test('gallery: Cloud 1-3, Local 4-7, reconnection keeps Local 8-10',
      () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    var networkOnline = true;
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      final step = calls.length;
      yield InferenceResponse.finalChunk(
        text: 'verified step $step',
        tokensGenerated: 1,
      );
      if (step == 3) networkOnline = false; // Enter tunnel.
      if (step == 7) networkOnline = true; // Exit tunnel.
    });
    await register(coordinator);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      isNetworkAvailable: () async => networkOnline,
      isLocalReady: () async => true,
      isConnectivityFailure: (error) => error is SocketException,
    );

    final outcome = await relay.run(
      ownerId: owner,
      executionId: 'gallery',
      sessionId: session,
      preferCloudAtStart: true,
      authorizeCloudText: (_) async => true,
      validateResult: (step, output) async =>
          output == 'verified step $step',
    );
    expect(outcome.isComplete, isTrue);
    expect(outcome.ledger.completedCount, 10);
    expect(calls.length, 10);
    expect(calls.take(3).every((r) =>
        r.routeDirective == InferenceRouteDirective.cloudOnly &&
        r.requireAutomaticCloudPolicy), isTrue);
    expect(calls.skip(3).every((r) =>
        r.routeDirective == InferenceRouteDirective.localOnly &&
        r.cloudProviderId == null), isTrue);
    expect(calls[7].prompt, contains('Checkpoint 7 completed by local'));
  });

  test('Cloud stream loses network mid-step: restore and retry only Local',
      () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    var networkOnline = true;
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      if (calls.length == 1) {
        // Model emitted tokens but no validated/committed checkpoint.
        yield InferenceResponse.token(text: 'incomplete first cloud step');
        networkOnline = false;
        throw const SocketException('Synthetic network loss');
      }
      yield InferenceResponse.finalChunk(
        text: 'local verified',
        tokensGenerated: 2,
      );
    });
    await register(coordinator, steps: 1);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      isNetworkAvailable: () async => networkOnline,
      isLocalReady: () async => true,
      isConnectivityFailure: (e) => e is SocketException,
    );

    final result = await relay.run(
      ownerId: owner,
      executionId: 'gallery',
      sessionId: session,
      preferCloudAtStart: true,
      authorizeCloudText: (_) async => true,
      validateResult: (step, output) async => output == 'local verified',
    );
    expect(result.isComplete, isTrue);
    expect(calls.length, 2);
    expect(calls.first.routeDirective, InferenceRouteDirective.cloudOnly);
    expect(calls.last.routeDirective, InferenceRouteDirective.localOnly);
    expect(result.ledger.completed.single.result, 'local verified');
  });

  test('Cloud provider error response: network outage reroutes to Local',
      () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    var online = true;
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      if (calls.length == 1) {
        yield InferenceResponse.token(text: 'partial Cloud answer');
        online = false;
        // Real CloudRuntimeProvider maps transport errors to terminal chunks
        // rather than throwing a raw SocketException through the stream.
        yield InferenceResponse.error('Gemini network unavailable.');
        return;
      }
      yield InferenceResponse.finalChunk(
        text: 'verified Local result',
        tokensGenerated: 4,
      );
    });
    await register(coordinator, steps: 1);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      isNetworkAvailable: () async => online,
      isLocalReady: () async => true,
      isConnectivityFailure: (error) =>
          error is HybridCheckpointStreamFailure &&
          error.providerError == 'Gemini network unavailable.',
    );
    final result = await relay.run(
      ownerId: owner,
      executionId: 'gallery',
      sessionId: session,
      preferCloudAtStart: true,
      authorizeCloudText: (_) async => true,
      validateResult: (_, output) async =>
          output == 'verified Local result',
    );
    expect(calls.length, 2);
    expect(calls.first.routeDirective, InferenceRouteDirective.cloudOnly);
    expect(calls.last.routeDirective, InferenceRouteDirective.localOnly);
    expect(result.ledger.completedCount, 1);
    expect(result.ledger.completed.single.result, 'verified Local result');
  });

  test('cancelled Cloud response never automatically replays in Local',
      () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    var online = true;
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      online = false;
      yield InferenceResponse.error(
        'Inference cancelled.',
        state: InferenceTerminalState.cancelled,
      );
    });
    await register(coordinator, steps: 1);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      isNetworkAvailable: () async => online,
      isLocalReady: () async => true,
      // Even a mistakenly permissive caller classifier cannot override an
      // explicit cancellation from the underlying inference service.
      isConnectivityFailure: (_) => true,
    );
    await expectLater(
      relay.run(
        ownerId: owner,
        executionId: 'gallery',
        sessionId: session,
        preferCloudAtStart: true,
        authorizeCloudText: (_) async => true,
        validateResult: (_, __) async => true,
      ),
      throwsA(isA<HybridCheckpointStreamFailure>()),
    );
    expect(calls.length, 1);
    expect((await coordinator.resume(
      ownerId: owner, executionId: 'gallery'))?.nextCheckpoint, 1);
  });

  test('ordinary model or validation failure never triggers Local replay',
      () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    var networkOnline = true;
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      networkOnline = false;
      throw StateError('Invalid independent output');
    });
    await register(coordinator, steps: 2);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      isNetworkAvailable: () async => networkOnline,
      isLocalReady: () async => true,
      isConnectivityFailure: (e) => e is SocketException,
    );
    await expectLater(
      relay.run(
        ownerId: owner,
        executionId: 'gallery',
        sessionId: session,
        preferCloudAtStart: true,
        authorizeCloudText: (_) async => true,
        validateResult: (step, text) async => true,
      ),
      throwsStateError,
    );
    expect(calls.length, 1);
    final restored = await coordinator.resume(
      ownerId: owner,
      executionId: 'gallery',
    );
    expect(restored?.nextCheckpoint, 1);
  });

  test('no Local readiness: Cloud loss fails without fabricated progress',
      () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    var online = true;
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      online = false;
      throw const SocketException('Synthetic drop');
    });
    await register(coordinator, steps: 1);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      isNetworkAvailable: () async => online,
      isLocalReady: () async => false,
      isConnectivityFailure: (e) => e is SocketException,
    );
    await expectLater(
      relay.run(
        ownerId: owner,
        executionId: 'gallery',
        sessionId: session,
        preferCloudAtStart: true,
        authorizeCloudText: (_) async => true,
        validateResult: (step, text) async => true,
      ),
      throwsStateError,
    );
    expect(calls.length, 1);
    final restored = await coordinator.resume(
      ownerId: owner,
      executionId: 'gallery',
    );
    expect(restored?.nextCheckpoint, 1);
  });

  test('restart after Local progress never automatically hands back to Cloud',
      () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      yield InferenceResponse.finalChunk(
        text: 'step ${request.checkpointId}',
        tokensGenerated: 1,
      );
    });
    await register(coordinator, steps: 3);
    final firstRelay = HybridCheckpointRelay(
      coordinator: coordinator,
      isNetworkAvailable: () async => false,
      isLocalReady: () async => true,
      isConnectivityFailure: (e) => e is SocketException,
    );
    var gate = 0;
    final paused = await firstRelay.run(
      ownerId: owner,
      executionId: 'gallery',
      sessionId: session,
      preferCloudAtStart: true,
      keepRunning: () async => gate++ == 0,
      validateResult: (_, __) async => true,
    );
    expect(paused.nextCheckpoint, 2);

    // Different coordinator instance simulates process restart with internet.
    final resumed = await HybridCheckpointRelay(
      coordinator: _coordinator(backend, (request) async* {
        calls.add(request);
        yield InferenceResponse.finalChunk(
          text: 'step ${request.checkpointId}',
          tokensGenerated: 1,
        );
      }),
      isNetworkAvailable: () async => true,
      isLocalReady: () async => true,
      isConnectivityFailure: (e) => e is SocketException,
    ).run(
      ownerId: owner,
      executionId: 'gallery',
      sessionId: session,
      preferCloudAtStart: true,
      authorizeCloudText: (_) async => true,
      validateResult: (_, __) async => true,
    );
    expect(resumed.isComplete, isTrue);
    expect(calls.length, 3);
    expect(calls.every((r) => r.routeDirective ==
        InferenceRouteDirective.localOnly), isTrue);
  });
}
