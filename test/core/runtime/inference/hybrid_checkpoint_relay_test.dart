import 'dart:async';
import 'dart:io';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_execution_coordinator.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_ledger.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_attempt_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_plan_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_relay.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_snapshot_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_step_runner.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_validated_connectivity.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Backend implements HybridProtectedSnapshotBackend {
  final values = <String, String>{};
  int readCalls = 0;

  @override
  Future<String?> read(String key) async {
    readCalls++;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

final class _FailIntentWritesBackend implements HybridProtectedSnapshotBackend {
  _FailIntentWritesBackend(this.delegate);
  final _Backend delegate;

  @override
  Future<String?> read(String key) => delegate.read(key);

  @override
  Future<void> write(String key, String value) async {
    throw StateError('Native encrypted intent storage unavailable');
  }

  @override
  Future<void> delete(String key) => delegate.delete(key);
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
  TestWidgetsFlutterBinding.ensureInitialized();
  const connectivityChannel = MethodChannel('test/hybrid_relay_android');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(connectivityChannel, null);
  });

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
        sessionId: session,
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
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
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

  test('Android OS network state drives relay only at checkpoint boundaries',
      () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    var validated = true;
    var nativeChecks = 0;
    messenger.setMockMethodCallHandler(connectivityChannel, (call) async {
      expect(call.method, 'hasValidatedInternet');
      nativeChecks++;
      return validated;
    });
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      final step = calls.length;
      yield InferenceResponse.finalChunk(
        text: 'validated $step',
        tokensGenerated: 2,
      );
      if (step == 3) validated = false;
      if (step == 7) validated = true;
    });
    await register(coordinator);
    final relay = HybridCheckpointRelay.android(
      coordinator: coordinator,
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
      connectivity: const HybridValidatedConnectivity(
        channel: connectivityChannel,
        platformOverride: TargetPlatform.android,
      ),
      isLocalReady: () async => true,
      isConnectivityFailure: (e) => e is SocketException,
    );
    expect(nativeChecks, 0); // Construction does not poll or phone home.

    final result = await relay.run(
      ownerId: owner,
      executionId: 'gallery',
      sessionId: session,
      preferCloudAtStart: true,
      authorizeCloudText: (_) async => true,
      validateResult: (step, output) async =>
          output == 'validated $step',
    );
    expect(result.ledger.completedCount, 10);
    expect(calls.take(3).every(
        (r) => r.routeDirective == InferenceRouteDirective.cloudOnly), isTrue);
    expect(calls.skip(3).every(
        (r) => r.routeDirective == InferenceRouteDirective.localOnly), isTrue);
    // Initial preference + one on-demand OS snapshot per checkpoint; there
    // is no timer, active provider probe, or continuous connectivity loop.
    expect(nativeChecks, lessThanOrEqualTo(12));
    expect(nativeChecks, greaterThanOrEqualTo(10));
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
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
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
      allowRetryAfterConnectionLoss: (_) async => true,
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
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
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
      allowRetryAfterConnectionLoss: (_) async => true,
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
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
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

  test('transport failure is not replayed without explicit idempotency approval',
      () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    var online = true;
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      online = false;
      yield InferenceResponse.error('Cloud network unavailable.');
    });
    await register(coordinator, steps: 1);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
      isNetworkAvailable: () async => online,
      isLocalReady: () async => true,
      isConnectivityFailure: (e) =>
          e is HybridCheckpointStreamFailure &&
          e.providerError == 'Cloud network unavailable.',
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
    expect(calls, hasLength(1));
    expect((await coordinator.resume(
      ownerId: owner, executionId: 'gallery'))?.nextCheckpoint, 1);

    // The network is restored before a separate explicit resume attempt.
    // Its Cloud request then fails again; the classifier must not allow the
    // second interrupted checkpoint to run locally without approval.
    online = true;
    // A trusted caller explicitly declines replay when side effects are
    // possible. Rejection retains the same checkpoint for later inspection.
    await expectLater(
      relay.run(
        ownerId: owner,
        executionId: 'gallery',
        sessionId: session,
        preferCloudAtStart: true,
        authorizeCloudText: (_) async => true,
        validateResult: (_, __) async => true,
        allowRetryAfterUncertainRestart: (_) async => true,
        allowRetryAfterConnectionLoss: (_) async => false,
      ),
      throwsA(isA<HybridCheckpointStreamFailure>()),
    );
    expect(calls, hasLength(2));
    expect(calls.every((r) =>
        r.routeDirective == InferenceRouteDirective.cloudOnly), isTrue);
  });

  test('two relays cannot concurrently claim one owner and execution',
      () async {
    final backend = _Backend();
    final entered = Completer<void>();
    final completeFirst = Completer<void>();
    var inferenceCalls = 0;
    final coordinator = _coordinator(backend, (request) async* {
      inferenceCalls++;
      if (!entered.isCompleted) entered.complete();
      await completeFirst.future;
      yield InferenceResponse.finalChunk(
        text: 'validated single result',
        tokensGenerated: 2,
      );
    });
    await register(coordinator, steps: 1);
    HybridCheckpointRelay relay() => HybridCheckpointRelay(
          coordinator: _coordinator(backend, (request) async* {
            inferenceCalls++;
            if (!entered.isCompleted) entered.complete();
            await completeFirst.future;
            yield InferenceResponse.finalChunk(
              text: 'validated single result',
              tokensGenerated: 2,
            );
          }),
          attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
          authorizeOwnerSession: (_, __) async => true,
          isNetworkAvailable: () async => false,
          isLocalReady: () async => true,
          isConnectivityFailure: (_) => false,
        );

    final first = relay().run(
      ownerId: owner,
      executionId: 'gallery',
      sessionId: session,
      preferCloudAtStart: false,
      validateResult: (_, __) async => true,
    );
    await entered.future;
    await expectLater(
      relay().run(
        ownerId: owner,
        executionId: 'gallery',
        sessionId: session,
        preferCloudAtStart: false,
        validateResult: (_, __) async => true,
      ),
      throwsStateError,
    );
    expect(inferenceCalls, 1);
    completeFirst.complete();
    final done = await first;
    expect(done.isComplete, isTrue);

    // Re-entering after the first relay finishes is allowed. No new model
    // call is made because the protected execution is already complete.
    final alreadyDone = await relay().run(
      ownerId: owner,
      executionId: 'gallery',
      sessionId: session,
      preferCloudAtStart: false,
      validateResult: (_, __) async => true,
    );
    expect(alreadyDone.isComplete, isTrue);
    expect(inferenceCalls, 1);
  });

  test('refused protected intent write never invokes Local inference',
      () async {
    final backend = _Backend();
    var inferenceCalls = 0;
    final coordinator = _coordinator(backend, (request) async* {
      inferenceCalls++;
      yield InferenceResponse.finalChunk(
        text: 'This must never run', tokensGenerated: 3,
      );
    });
    await register(coordinator, steps: 1);
    final journal = HybridCheckpointAttemptJournal(
      backend: _FailIntentWritesBackend(backend),
    );
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: journal,
      authorizeOwnerSession: (_, __) async => true,
      isNetworkAvailable: () async => false,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    await expectLater(
      relay.run(
        ownerId: owner, executionId: 'gallery', sessionId: session,
        preferCloudAtStart: false, validateResult: (_, __) async => true,
      ),
      throwsStateError,
    );
    expect(inferenceCalls, 0);
    expect((await coordinator.resume(
      ownerId: owner, executionId: 'gallery'))?.nextCheckpoint, 1);
  });

  test('cross-chat relay cannot read a registered HYBRID execution',
      () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      yield InferenceResponse.finalChunk(
        text: 'do not leak another chat', tokensGenerated: 3,
      );
    });
    await register(coordinator, steps: 1);
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    var checks = 0;
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: journal,
      authorizeOwnerSession: (_, __) async {
        checks++;
        return true; // Same owner authorized for both chat sessions.
      },
      isNetworkAvailable: () async => false,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    await expectLater(
      relay.run(
        ownerId: owner, executionId: 'gallery',
        sessionId: 'another-chat', preferCloudAtStart: false,
        validateResult: (_, __) async => true,
      ),
      throwsStateError,
    );
    expect(checks, 1);
    expect(calls, isEmpty);
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: 'gallery'), isNull);
    expect((await coordinator.resume(
      ownerId: owner, executionId: 'gallery'))?.nextCheckpoint, 1);
  });

  test('unauthorized owner/session cannot read protected execution data',
      () async {
    final backend = _Backend();
    var modelCalls = 0;
    final coordinator = _coordinator(backend, (request) async* {
      modelCalls++;
      yield InferenceResponse.finalChunk(text: 'never', tokensGenerated: 1);
    });
    await register(coordinator, steps: 1);
    final protectedReadsBefore = backend.readCalls;
    var authorizations = 0;
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (ownerId, sessionId) async {
        authorizations++;
        expect(ownerId, owner);
        expect(sessionId, session);
        return false;
      },
      isNetworkAvailable: () async => true,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    await expectLater(
      relay.run(
        ownerId: owner, executionId: 'gallery', sessionId: session,
        preferCloudAtStart: true,
        authorizeCloudText: (_) async => true,
        validateResult: (_, __) async => true,
      ),
      throwsStateError,
    );
    expect(authorizations, 1);
    expect(backend.readCalls, protectedReadsBefore);
    expect(modelCalls, 0);
  });

  test('owner/session revocation stops before a second checkpoint',
      () async {
    final backend = _Backend();
    var modelCalls = 0;
    var authorizationChecks = 0;
    final coordinator = _coordinator(backend, (request) async* {
      modelCalls++;
      yield InferenceResponse.finalChunk(
        text: 'finished $modelCalls', tokensGenerated: 2,
      );
    });
    await register(coordinator, steps: 2);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => ++authorizationChecks <= 4,
      isNetworkAvailable: () async => false,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    await expectLater(
      relay.run(
        ownerId: owner, executionId: 'gallery', sessionId: session,
        preferCloudAtStart: false,
        validateResult: (_, output) async => output.startsWith('finished'),
      ),
      throwsStateError,
    );
    expect(authorizationChecks, 5);
    expect(modelCalls, 1);
    final restored = await coordinator.resume(
      ownerId: owner, executionId: 'gallery',
    );
    expect(restored?.ledger.completedCount, 1);
    expect(restored?.nextCheckpoint, 2);
    expect(await HybridCheckpointAttemptJournal(backend: backend)
        .pendingCheckpoint(ownerId: owner, executionId: 'gallery'), isNull);
  });

  test('user cancels during Local streaming: no checkpoint is committed',
      () async {
    final backend = _Backend();
    var cancelled = false;
    var modelCalls = 0;
    final coordinator = _coordinator(backend, (request) async* {
      modelCalls++;
      yield InferenceResponse.token(text: 'temporary token');
      cancelled = true; // Stop was pressed while the stream was active.
      yield InferenceResponse.finalChunk(
        text: 'should not commit', tokensGenerated: 2,
      );
    });
    await register(coordinator, steps: 1);
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: journal,
      authorizeOwnerSession: (_, __) async => true,
      isNetworkAvailable: () async => false,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    await expectLater(
      relay.run(
        ownerId: owner, executionId: 'gallery', sessionId: session,
        preferCloudAtStart: false,
        isCancellationRequested: () async => cancelled,
        validateResult: (_, __) async => true,
      ),
      throwsStateError,
    );
    expect(modelCalls, 1);
    expect((await coordinator.resume(
      ownerId: owner, executionId: 'gallery'))?.ledger.completedCount, 0);
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: 'gallery'), 1);
  });

  test('user cancels during Cloud consent: no model or false intent',
      () async {
    final backend = _Backend();
    var cancelled = false;
    var modelCalls = 0;
    final coordinator = _coordinator(backend, (request) async* {
      modelCalls++;
      yield InferenceResponse.finalChunk(
        text: 'should not run', tokensGenerated: 2,
      );
    });
    await register(coordinator, steps: 1);
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: journal,
      authorizeOwnerSession: (_, __) async => true,
      isNetworkAvailable: () async => true,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    await expectLater(
      relay.run(
        ownerId: owner, executionId: 'gallery', sessionId: session,
        preferCloudAtStart: true,
        isCancellationRequested: () async => cancelled,
        authorizeCloudText: (_) async {
          cancelled = true;
          return true;
        },
        validateResult: (_, __) async => true,
      ),
      throwsStateError,
    );
    expect(modelCalls, 0);
    expect((await coordinator.resume(
      ownerId: owner, executionId: 'gallery'))?.nextCheckpoint, 1);
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: 'gallery'), isNull);
  });

  test('logout during inference blocks commit and retains protected intent',
      () async {
    final backend = _Backend();
    var authorized = true;
    var modelCalls = 0;
    final coordinator = _coordinator(backend, (request) async* {
      modelCalls++;
      yield InferenceResponse.token(text: 'model was answering');
      authorized = false; // Revoked while the stream was active.
      yield InferenceResponse.finalChunk(
        text: 'result after logout', tokensGenerated: 3,
      );
    });
    await register(coordinator, steps: 1);
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: journal,
      authorizeOwnerSession: (_, __) async => authorized,
      isNetworkAvailable: () async => false,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    await expectLater(
      relay.run(
        ownerId: owner, executionId: 'gallery', sessionId: session,
        preferCloudAtStart: false,
        validateResult: (_, __) async => true,
      ),
      throwsStateError,
    );
    expect(modelCalls, 1);
    // An uncommitted but already started model step remains ambiguous.
    expect((await coordinator.resume(
      ownerId: owner, executionId: 'gallery'))?.ledger.completedCount, 0);
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: 'gallery'), 1);
  });

  test('logout during independent validation blocks durable checkpoint',
      () async {
    final backend = _Backend();
    var authorized = true;
    final coordinator = _coordinator(backend, (request) async* {
      yield InferenceResponse.finalChunk(
        text: 'uncommitted result', tokensGenerated: 3,
      );
    });
    await register(coordinator, steps: 1);
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: journal,
      authorizeOwnerSession: (_, __) async => authorized,
      isNetworkAvailable: () async => false,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    await expectLater(
      relay.run(
        ownerId: owner, executionId: 'gallery', sessionId: session,
        preferCloudAtStart: false,
        validateResult: (_, __) async {
          authorized = false;
          return true;
        },
      ),
      throwsStateError,
    );
    expect((await coordinator.resume(
      ownerId: owner, executionId: 'gallery'))?.ledger.completedCount, 0);
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: 'gallery'), 1);
  });

  test('owner authorization revoked during Cloud consent blocks inference',
      () async {
    final backend = _Backend();
    var calls = 0;
    var authorized = true;
    var permissionChecks = 0;
    final coordinator = _coordinator(backend, (request) async* {
      calls++;
      yield InferenceResponse.finalChunk(
        text: 'should not be sent', tokensGenerated: 1,
      );
    });
    await register(coordinator, steps: 1);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async {
        permissionChecks++;
        return authorized;
      },
      isNetworkAvailable: () async => true,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    await expectLater(
      relay.run(
        ownerId: owner, executionId: 'gallery', sessionId: session,
        preferCloudAtStart: true,
        authorizeCloudText: (_) async {
          authorized = false; // E.g., logout during consent.
          return true;
        },
        validateResult: (_, __) async => true,
      ),
      throwsStateError,
    );
    expect(permissionChecks, 3);
    expect(calls, 0);
    expect(await HybridCheckpointAttemptJournal(backend: backend)
        .pendingCheckpoint(ownerId: owner, executionId: 'gallery'), isNull);
    expect((await coordinator.resume(
      ownerId: owner, executionId: 'gallery'))?.nextCheckpoint, 1);
  });

  test('Cloud consent denial never leaves a false pending intent', () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      yield InferenceResponse.finalChunk(
        text: 'approved output', tokensGenerated: 2,
      );
    });
    await register(coordinator, steps: 1);
    HybridCheckpointRelay createRelay() => HybridCheckpointRelay(
      coordinator: _coordinator(backend, (request) async* {
        calls.add(request);
        yield InferenceResponse.finalChunk(
          text: 'approved output', tokensGenerated: 2,
        );
      }),
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
      isNetworkAvailable: () async => true,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    var consentCalls = 0;
    await expectLater(
      createRelay().run(
        ownerId: owner, executionId: 'gallery', sessionId: session,
        preferCloudAtStart: true,
        authorizeCloudText: (_) async {
          consentCalls++;
          return false;
        },
        validateResult: (_, __) async => true,
      ),
      throwsStateError,
    );
    expect(consentCalls, 1);
    expect(calls, isEmpty);
    expect(await HybridCheckpointAttemptJournal(backend: backend)
        .pendingCheckpoint(ownerId: owner, executionId: 'gallery'), isNull);
    final done = await createRelay().run(
      ownerId: owner, executionId: 'gallery', sessionId: session,
      preferCloudAtStart: true,
      authorizeCloudText: (_) async => true,
      validateResult: (_, text) async => text == 'approved output',
    );
    expect(done.isComplete, isTrue);
    expect(calls, hasLength(1));
    expect(await HybridCheckpointAttemptJournal(backend: backend)
        .pendingCheckpoint(ownerId: owner, executionId: 'gallery'), isNull);
  });

  test('protected intent exists before the model stream receives a request',
      () async {
    final backend = _Backend();
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    final coordinator = _coordinator(backend, (request) async* {
      final pending = await journal.pendingCheckpoint(
        ownerId: owner, executionId: 'gallery',
      );
      expect(pending, 1); // No model token before durable intent readback.
      yield InferenceResponse.finalChunk(
        text: 'step complete', tokensGenerated: 2,
      );
    });
    await register(coordinator, steps: 1);
    final relay = HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: journal,
      authorizeOwnerSession: (_, __) async => true,
      isNetworkAvailable: () async => false,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    final completed = await relay.run(
      ownerId: owner, executionId: 'gallery', sessionId: session,
      preferCloudAtStart: false,
      validateResult: (_, text) async => text == 'step complete',
    );
    expect(completed.isComplete, isTrue);
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: 'gallery'), isNull);
  });

  test('process restart refuses to repeat an unconfirmed Cloud attempt',
      () async {
    final backend = _Backend();
    final calls = <InferenceRequest>[];
    var firstRun = true;
    final coordinator = _coordinator(backend, (request) async* {
      calls.add(request);
      if (firstRun) {
        firstRun = false;
        yield InferenceResponse.error('Remote outcome is unknown');
        return;
      }
      yield InferenceResponse.finalChunk(text: 'verified retry', tokensGenerated: 2);
    });
    await register(coordinator, steps: 1);
    HybridCheckpointRelay relay() => HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
      isNetworkAvailable: () async => true,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    );
    await expectLater(
      relay().run(ownerId: owner, executionId: 'gallery', sessionId: session,
        preferCloudAtStart: true, authorizeCloudText: (_) async => true,
        validateResult: (_, __) async => true),
      throwsA(isA<HybridCheckpointStreamFailure>()),
    );
    expect(calls, hasLength(1));
    expect(await HybridCheckpointAttemptJournal(backend: backend)
        .pendingCheckpoint(ownerId: owner, executionId: 'gallery'), 1);
    await expectLater(
      relay().run(ownerId: owner, executionId: 'gallery', sessionId: session,
        preferCloudAtStart: true, authorizeCloudText: (_) async => true,
        validateResult: (_, __) async => true),
      throwsStateError,
    );
    expect(calls, hasLength(1));
    final result = await relay().run(
      ownerId: owner, executionId: 'gallery', sessionId: session,
      preferCloudAtStart: true, authorizeCloudText: (_) async => true,
      allowRetryAfterUncertainRestart: (_) async => true,
      validateResult: (_, text) async => text == 'verified retry',
    );
    expect(result.isComplete, isTrue);
    expect(calls, hasLength(2));
    expect(await HybridCheckpointAttemptJournal(backend: backend)
        .pendingCheckpoint(ownerId: owner, executionId: 'gallery'), isNull);
  });

  test('crash after committed result never replays a stale pending marker',
      () async {
    final backend = _Backend();
    var calls = 0;
    final coordinator = _coordinator(backend, (request) async* {
      calls++;
      yield InferenceResponse.finalChunk(
        text: 'completed before crash', tokensGenerated: 2,
      );
    });
    await register(coordinator, steps: 1);
    final journal = HybridCheckpointAttemptJournal(backend: backend);
    await journal.markBeforeInference(
      ownerId: owner, executionId: 'gallery', checkpoint: 1,
    );
    final saved = (await coordinator.resume(
      ownerId: owner, executionId: 'gallery'))!;
    final lease = saved.ledger.beginAttempt(
      attemptId: 'before-crash', executor: HybridCheckpointExecutor.cloud,
    );
    await coordinator.executeNext(
      ownerId: owner, execution: saved, lease: lease,
      sessionId: session, isOffline: false,
      authorizeCloudText: (_) async => true,
      validateResult: (_) async => true,
    );
    expect(calls, 1);
    final finished = await HybridCheckpointRelay(
      coordinator: coordinator,
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
      isNetworkAvailable: () async => true,
      isLocalReady: () async => true,
      isConnectivityFailure: (_) => false,
    ).run(
      ownerId: owner, executionId: 'gallery', sessionId: session,
      preferCloudAtStart: true, validateResult: (_, __) async => true,
    );
    expect(finished.isComplete, isTrue);
    expect(calls, 1);
    expect(await journal.pendingCheckpoint(
      ownerId: owner, executionId: 'gallery'), isNull);
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
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
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
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
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
        // Even when retry is explicitly safe, Local readiness is required.
        allowRetryAfterConnectionLoss: (_) async => true,
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
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
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
      attemptJournal: HybridCheckpointAttemptJournal(backend: backend),
      authorizeOwnerSession: (_, __) async => true,
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
