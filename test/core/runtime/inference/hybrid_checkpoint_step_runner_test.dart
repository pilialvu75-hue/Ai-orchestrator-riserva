import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/directive_aware_inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_ledger.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_snapshot_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_step_runner.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemorySecureBackend implements HybridProtectedSnapshotBackend {
  final records = <String, String>{};

  @override
  Future<String?> read(String key) async => records[key];

  @override
  Future<void> write(String key, String value) async {
    records[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    records.remove(key);
  }
}

CloudRuntimeProvider _cloud({bool available = true, bool allowed = true}) =>
    CloudRuntimeProvider(
      sendQuery: (String provider, AiRequest req) async => AiResponse(
        text: 'not called',
        model: 'fake',
        tokensUsed: 1,
        timestamp: 0,
      ),
      supportedProviders: () => const <String>['gemini'],
      isProviderAvailable: (_) => available,
      providerDisplayName: ([provider]) => provider ?? 'gemini',
      automaticUseAllowedForTask: (_, __) => allowed,
    );

final class _FakeLocalInferenceProvider extends LocalRuntimeProvider {
  _FakeLocalInferenceProvider(this.onInfer);
  final void Function() onInfer;

  @override
  bool supportsModel(AiModel model) => true;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    onInfer();
    yield InferenceResponse.finalChunk(
      text: 'LOCAL finished planned step',
      tokensGenerated: 4,
      model: 'test-local',
    );
  }
}

void main() {
  const owner = 'test-owner';
  const session = 'test-session';

  test('opt-in runner uses the production DirectiveAwareInferenceService',
      () async {
    const selected = AiModel(
      id: 'test_local_2b',
      displayName: 'Local test',
      fileName: 'test.gguf',
      downloadUrl: 'https://example.test/model.gguf',
      version: '1',
      sizeBytes: 123,
      description: 'Synthetic validated model',
      isDownloaded: true,
      localPath: '/tmp/test.gguf',
      validationStatus: ModelValidationStatus.validatedOk,
    );
    var cloudCalls = 0;
    var localCalls = 0;
    final cloud = CloudRuntimeProvider(
      sendQuery: (String providerId, AiRequest request) async {
        cloudCalls++;
        expect(providerId, 'gemini');
        return AiResponse(
          text: 'CLOUD finished planned step',
          model: 'synthetic-cloud',
          tokensUsed: 7,
          timestamp: 0,
        );
      },
      supportedProviders: () => const ['gemini'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([provider]) => provider ?? 'gemini',
      automaticUseAllowedForTask: (_, __) => true,
    );
    final inference = DirectiveAwareInferenceService(
      loadSelectedModel: () async => selected,
      loadRuntimeMode: () async => AiRuntimeMode.hybrid,
      runtimeProvider: _FakeLocalInferenceProvider(() => localCalls++),
      cloudRuntimeProvider: cloud,
      sessionManager: RuntimeSessionManager(),
    );

    final store =
        HybridCheckpointSnapshotStore(backend: _MemorySecureBackend());
    final ledger = HybridCheckpointLedger(
      executionId: 'real-directive-adapter',
      totalCheckpoints: 2,
    );
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());

    final runner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: cloud,
      streamInference: inference.stream,
    );
    final cloudLease = ledger.beginAttempt(
      attemptId: 'cloud-attempt',
      executor: HybridCheckpointExecutor.cloud,
    );
    final cloudResult = await runner.executeNext(
      ownerId: owner,
      ledger: ledger,
      lease: cloudLease,
      sessionId: 'real-inference-session',
      stepInstruction: 'Correggi il codice Dart',
      isOffline: false,
      authorizeCloudText: (_) async => true,
      validateResult: (text) async =>
          text == 'CLOUD finished planned step',
    );
    expect(cloudResult, 'CLOUD finished planned step');
    expect(cloudCalls, 1);
    expect(localCalls, 0);

    ledger.interruptAttempt(cloudLease);
    final localLease = ledger.beginAttempt(
      attemptId: 'local-attempt',
      executor: HybridCheckpointExecutor.local,
    );
    final localResult = await runner.executeNext(
      ownerId: owner,
      ledger: ledger,
      lease: localLease,
      sessionId: 'real-inference-session',
      stepInstruction: 'Completa il passaggio finale',
      isOffline: true,
      validateResult: (text) async =>
          text == 'LOCAL finished planned step',
    );
    expect(localResult, 'LOCAL finished planned step');
    expect(cloudCalls, 1);
    expect(localCalls, 1);
    expect(ledger.isComplete, isTrue);
    final recovered = await store.load(
      ownerId: owner,
      executionId: 'real-directive-adapter',
    );
    expect(recovered?.completedCount, 2);
  });

  test('real inference boundary: Cloud 1-3, Local 4-7, reconnection Local 8-10',
      () async {
    final backend = _MemorySecureBackend();
    var store = HybridCheckpointSnapshotStore(backend: backend);
    var ledger = HybridCheckpointLedger(
      executionId: 'gallery-inference-10',
      totalCheckpoints: 10,
    );
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());

    final calls = <InferenceRequest>[];
    final runner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: _cloud(),
      streamInference: (request) async* {
        calls.add(request);
        yield InferenceResponse.finalChunk(
          text: 'Verified output ${request.checkpointId}',
          tokensGenerated: 6,
          model: 'fake-model',
          providerId: request.cloudProviderId,
        );
      },
    );
    var cloudAuthorizations = 0;

    Future<void> execute(
      HybridCheckpointStepRunner activeRunner,
      HybridCheckpointLedger activeLedger,
      HybridAttemptLease lease,
      int number, {
      bool offline = false,
    }) async {
      final result = await activeRunner.executeNext(
        ownerId: owner,
        ledger: activeLedger,
        lease: lease,
        sessionId: session,
        stepInstruction: 'Correggi il codice Flutter, passaggio $number',
        isOffline: offline,
        validateResult: (result) async =>
            result == 'Verified output checkpoint-$number',
        authorizeCloudText: (outbound) async {
          cloudAuthorizations++;
          expect(outbound, contains('Current step:'));
          return true;
        },
      );
      expect(result, 'Verified output checkpoint-$number');
      expect(activeLedger.completedCount, number);
    }

    final cloud = ledger.beginAttempt(
      attemptId: 'cloud-a',
      executor: HybridCheckpointExecutor.cloud,
    );
    for (var i = 1; i <= 3; i++) {
      await execute(runner, ledger, cloud, i);
    }
    expect(cloudAuthorizations, 3);
    expect(calls.take(3).every((r) =>
        r.routeDirective == InferenceRouteDirective.cloudOnly &&
        r.cloudProviderId == 'gemini' &&
        !r.allowCloudProviderFailover &&
        r.requireAutomaticCloudPolicy), isTrue);

    // The Cloud connection is lost, and Local takes over after a restart.
    store = HybridCheckpointSnapshotStore(backend: backend);
    ledger = (await store.load(
      ownerId: owner,
      executionId: 'gallery-inference-10',
    ))!;
    expect(ledger.nextCheckpoint, 4);
    final local = ledger.beginAttempt(
      attemptId: 'local-b',
      executor: HybridCheckpointExecutor.local,
    );
    final localRunner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: _cloud(),
      streamInference: runnerStream(calls),
    );
    for (var i = 4; i <= 7; i++) {
      await execute(localRunner, ledger, local, i, offline: true);
    }

    // Network reconnect alone does not change owner of the work.
    expect(ledger.nextCheckpoint, 8);
    expect(calls.skip(3).take(4).every((r) =>
        r.routeDirective == InferenceRouteDirective.localOnly &&
        r.isOffline &&
        !r.allowWebSearchTool &&
        r.cloudProviderId == null), isTrue);

    for (var i = 8; i <= 10; i++) {
      await execute(localRunner, ledger, local, i);
    }
    expect(ledger.isComplete, isTrue);
    expect(cloudAuthorizations, 3);
    expect(calls.length, 10);
    final verified = (await store.load(
      ownerId: owner,
      executionId: 'gallery-inference-10',
    ))!;
    expect(verified.completedCount, 10);
    expect(
      verified.completed.map((x) => x.number),
      orderedEquals(List.generate(10, (i) => i + 1)),
    );
    // Every continuation contains previously completed *explicit* results.
    expect(calls[3].prompt, contains('Checkpoint 3 completed by cloud'));
    expect(calls[7].prompt, contains('Checkpoint 7 completed by local'));
  });

  test('HYBRID provider dispatch rechecks AUTO policy after approval',
      () async {
    // Simulate the user revoking AUTO access between provider recommendation
    // and the actual CloudRuntimeProvider send. A pinned Cloud provider must
    // NOT turn an automatic HYBRID route into a manual paid Cloud request.
    var autoAllowed = true;
    var outboundCalls = 0;
    final cloud = CloudRuntimeProvider(
      sendQuery: (String providerId, AiRequest request) async {
        outboundCalls++;
        return AiResponse(
          text: 'Unexpected remote request',
          model: 'remote',
          tokensUsed: 1,
          timestamp: 0,
        );
      },
      supportedProviders: () => const ['gemini'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([provider]) => provider ?? 'gemini',
      automaticUseAllowedForTask: (_, __) => autoAllowed,
    );
    final service = DirectiveAwareInferenceService(
      loadSelectedModel: () async => null,
      loadRuntimeMode: () async => AiRuntimeMode.hybrid,
      runtimeProvider: _FakeLocalInferenceProvider(() {}),
      cloudRuntimeProvider: cloud,
      sessionManager: RuntimeSessionManager(),
    );
    final store = HybridCheckpointSnapshotStore(
      backend: _MemorySecureBackend(),
    );
    final ledger = HybridCheckpointLedger(
      executionId: 'automatic-policy-revoked',
      totalCheckpoints: 1,
    );
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());
    final lease = ledger.beginAttempt(
      attemptId: 'cloud-a',
      executor: HybridCheckpointExecutor.cloud,
    );
    final runner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: cloud,
      streamInference: service.stream,
    );

    await expectLater(
      runner.executeNext(
        ownerId: owner,
        ledger: ledger,
        lease: lease,
        sessionId: session,
        stepInstruction: 'Correggi questo codice Dart',
        isOffline: false,
        validateResult: (_) async => true,
        authorizeCloudText: (_) async {
          autoAllowed = false; // Changed before provider execution.
          return true;
        },
      ),
      throwsA(isA<HybridCheckpointStreamFailure>()),
    );
    expect(outboundCalls, 0);
    expect(ledger.completedCount, 0);
    final restored = await store.load(
      ownerId: owner,
      executionId: 'automatic-policy-revoked',
    );
    expect(restored?.nextCheckpoint, 1);
  });

  test('Cloud requires both task-aware AUTO policy and consent to full text',
      () async {
    final store =
        HybridCheckpointSnapshotStore(backend: _MemorySecureBackend());
    final ledger = HybridCheckpointLedger(
      executionId: 'no-silent-cloud',
      totalCheckpoints: 2,
    );
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());
    final lease = ledger.beginAttempt(
      attemptId: 'cloud',
      executor: HybridCheckpointExecutor.cloud,
    );
    var calls = 0;
    final runner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: _cloud(allowed: false),
      streamInference: (request) async* {
        calls++;
        yield InferenceResponse.finalChunk(
          text: 'unsafe call', tokensGenerated: 1,
        );
      },
    );

    await expectLater(
      runner.executeNext(
        ownerId: owner,
        ledger: ledger,
        lease: lease,
        sessionId: session,
        stepInstruction: 'Debug Flutter code',
        isOffline: false,
        validateResult: (_) async => true,
        authorizeCloudText: (_) async => true,
      ),
      throwsStateError,
    );
    expect(calls, 0);
    expect(ledger.inFlightCheckpoint, isNull);
    expect(ledger.completedCount, 0);
  });

  test('offline and missing consent reject Cloud before any inference', () async {
    final store =
        HybridCheckpointSnapshotStore(backend: _MemorySecureBackend());
    final ledger = HybridCheckpointLedger(
      executionId: 'offline-gate',
      totalCheckpoints: 2,
    );
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());
    final lease = ledger.beginAttempt(
      attemptId: 'cloud',
      executor: HybridCheckpointExecutor.cloud,
    );
    var calls = 0;
    final runner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: _cloud(),
      streamInference: (r) async* {
        calls++;
        yield InferenceResponse.finalChunk(text: 'no', tokensGenerated: 1);
      },
    );
    for (final isOffline in <bool>[true, false]) {
      await expectLater(
        runner.executeNext(
          ownerId: owner,
          ledger: ledger,
          lease: lease,
          sessionId: session,
          stepInstruction: 'Debug this code',
          isOffline: isOffline,
          validateResult: (_) async => true,
        ),
        throwsStateError,
      );
    }
    expect(calls, 0);
    expect(ledger.nextCheckpoint, 1);
  });

  test('partial Cloud stream plus failure is not marked complete', () async {
    final store =
        HybridCheckpointSnapshotStore(backend: _MemorySecureBackend());
    final ledger = HybridCheckpointLedger(
      executionId: 'cloud-drop',
      totalCheckpoints: 2,
    );
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());
    final lease = ledger.beginAttempt(
      attemptId: 'cloud-1',
      executor: HybridCheckpointExecutor.cloud,
    );
    final runner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: _cloud(),
      streamInference: (r) async* {
        yield InferenceResponse.token(text: 'Incomplete Cloud text');
        yield InferenceResponse.error('Network disconnected.');
      },
    );
    await expectLater(
      runner.executeNext(
        ownerId: owner,
        ledger: ledger,
        lease: lease,
        sessionId: session,
        stepInstruction: 'Debug Flutter app',
        isOffline: false,
        validateResult: (_) async => true,
        authorizeCloudText: (_) async => true,
      ),
      throwsA(isA<HybridCheckpointStreamFailure>()),
    );
    expect(ledger.completedCount, 0);
    expect((await store.load(ownerId: owner, executionId: 'cloud-drop'))!
        .completedCount, 0);
    expect(() => ledger.startCheckpoint(lease), throwsStateError);

    // A separate Local Attempt continues from the authoritative store.
    final recovered =
        (await store.load(ownerId: owner, executionId: 'cloud-drop'))!;
    final local = recovered.beginAttempt(
      attemptId: 'local-2',
      executor: HybridCheckpointExecutor.local,
    );
    final localRunner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: _cloud(),
      streamInference: runnerStream(<InferenceRequest>[]),
    );
    await localRunner.executeNext(
      ownerId: owner,
      ledger: recovered,
      lease: local,
      sessionId: session,
      stepInstruction: 'Debug Flutter app',
      isOffline: true,
      validateResult: (result) async => result.isNotEmpty,
    );
    expect(recovered.completedCount, 1);
  });


  test('oversized streaming text stops before independent validation and persistence',
      () async {
    final store =
        HybridCheckpointSnapshotStore(backend: _MemorySecureBackend());
    final ledger =
        HybridCheckpointLedger(executionId: 'oversized-stream', totalCheckpoints: 1);
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());
    final lease = ledger.beginAttempt(
      attemptId: 'local-stream',
      executor: HybridCheckpointExecutor.local,
    );
    var validated = 0;
    var emitted = 0;
    final runner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: _cloud(),
      streamInference: (request) async* {
        for (var i = 0; i < 50; i++) {
          emitted++;
          yield InferenceResponse.token(text: 'x' * 1024);
        }
        yield InferenceResponse.finalChunk(
          text: 'should never finish', tokensGenerated: 3,
        );
      },
    );
    await expectLater(
      runner.executeNext(
        ownerId: owner,
        ledger: ledger,
        lease: lease,
        sessionId: session,
        stepInstruction: 'Summarize only one verified step',
        isOffline: true,
        validateResult: (_) async {
          validated++;
          return true;
        },
      ),
      throwsStateError,
    );
    expect(emitted, lessThan(50)); // Stops stream without consuming the rest.
    expect(validated, 0);
    expect(ledger.completedCount, 0);
    expect((await store.load(
      ownerId: owner, executionId: 'oversized-stream'))?.nextCheckpoint, 1);
  });

  test('large final snapshot is rejected before validation or checkpoint write',
      () async {
    final store =
        HybridCheckpointSnapshotStore(backend: _MemorySecureBackend());
    final ledger =
        HybridCheckpointLedger(executionId: 'oversized-final', totalCheckpoints: 1);
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());
    final lease = ledger.beginAttempt(
      attemptId: 'cloud-large',
      executor: HybridCheckpointExecutor.cloud,
    );
    var validated = 0;
    final runner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: _cloud(),
      streamInference: (request) async* {
        yield InferenceResponse.finalChunk(
          text: 'x' *
              (HybridCheckpointStepRunner.maxCheckpointOutputCharacters + 1),
          tokensGenerated: 20000,
        );
      },
    );
    await expectLater(
      runner.executeNext(
        ownerId: owner,
        ledger: ledger,
        lease: lease,
        sessionId: session,
        stepInstruction: 'Answer a bounded question',
        isOffline: false,
        authorizeCloudText: (_) async => true,
        validateResult: (_) async {
          validated++;
          return true;
        },
      ),
      throwsStateError,
    );
    expect(validated, 0);
    expect(ledger.completedCount, 0);
    expect((await store.load(
      ownerId: owner, executionId: 'oversized-final'))?.completedCount, 0);
  });

  test('data after terminal success cannot silently change a checkpoint',
      () async {
    final store =
        HybridCheckpointSnapshotStore(backend: _MemorySecureBackend());
    final ledger =
        HybridCheckpointLedger(executionId: 'trailing-stream', totalCheckpoints: 1);
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());
    final lease = ledger.beginAttempt(
      attemptId: 'local-trailing',
      executor: HybridCheckpointExecutor.local,
    );
    final runner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: _cloud(),
      streamInference: (request) async* {
        yield InferenceResponse.finalChunk(
          text: 'Verified answer', tokensGenerated: 2,
        );
        yield InferenceResponse.token(text: 'Unexpected trailing text');
      },
    );
    await expectLater(
      runner.executeNext(
        ownerId: owner,
        ledger: ledger,
        lease: lease,
        sessionId: session,
        stepInstruction: 'Verify one answer',
        isOffline: true,
        validateResult: (_) async => true,
      ),
      throwsStateError,
    );
    expect(ledger.completedCount, 0);
    expect((await store.load(
      ownerId: owner, executionId: 'trailing-stream'))?.nextCheckpoint, 1);
  });

  test('independent validation rejects model output without checkpoint',
      () async {
    final store =
        HybridCheckpointSnapshotStore(backend: _MemorySecureBackend());
    final ledger = HybridCheckpointLedger(
      executionId: 'no-self-certification',
      totalCheckpoints: 1,
    );
    await store.saveSnapshot(ownerId: owner, snapshot: ledger.toJson());
    final lease = ledger.beginAttempt(
      attemptId: 'local',
      executor: HybridCheckpointExecutor.local,
    );
    final runner = HybridCheckpointStepRunner(
      snapshotStore: store,
      cloudRuntimeProvider: _cloud(),
      streamInference: runnerStream(<InferenceRequest>[]),
    );
    await expectLater(
      runner.executeNext(
        ownerId: owner,
        ledger: ledger,
        lease: lease,
        sessionId: session,
        stepInstruction: 'Solve problem',
        isOffline: true,
        validateResult: (_) async => false,
      ),
      throwsStateError,
    );
    expect(ledger.completedCount, 0);
    expect((await store.load(
      ownerId: owner,
      executionId: 'no-self-certification',
    ))!.completedCount, 0);
  });
}

Stream<InferenceResponse> Function(InferenceRequest) runnerStream(
  List<InferenceRequest> calls,
) {
  return (InferenceRequest request) async* {
    calls.add(request);
    yield InferenceResponse.finalChunk(
      text: 'Verified output ${request.checkpointId}',
      tokensGenerated: 4,
      model: 'local',
    );
  };
}
