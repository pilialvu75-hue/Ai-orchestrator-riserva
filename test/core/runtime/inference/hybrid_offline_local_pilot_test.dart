import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_attempt_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_execution_coordinator.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_plan_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_snapshot_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_step_runner.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_session_store.dart';
import 'package:ai_orchestrator/features/chat/data/services/hybrid_local_session_authorizer.dart';
import 'package:ai_orchestrator/features/chat/data/services/hybrid_offline_local_pilot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _ProtectedBackend implements HybridProtectedSnapshotBackend {
  final Map<String, String> values = <String, String>{};

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

void main() {
  late Database db;
  late _ProtectedBackend protected;
  late ChatSessionStore sessions;
  late HybridLocalSessionAuthorizer auth;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE user_preferences (pref_key TEXT PRIMARY KEY, pref_value TEXT NOT NULL)
    ''');
    await db.execute('''
      CREATE TABLE chat_sessions (
        id TEXT PRIMARY KEY, created_at INTEGER NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE chat_history (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
        role TEXT NOT NULL, content TEXT NOT NULL DEFAULT '',
        timestamp INTEGER NOT NULL
      )
    ''');
    protected = _ProtectedBackend();
    sessions = ChatSessionStore.forTesting(db);
    auth = HybridLocalSessionAuthorizer(backend: protected, sessions: sessions);
  });

  tearDown(() async => db.close());

  final requests = <InferenceRequest>[];

  HybridCheckpointExecutionCoordinator coordinator({
    bool failFirst = false,
  }) {
    final snapshots = HybridCheckpointSnapshotStore(backend: protected);
    var shouldFail = failFirst;
    return HybridCheckpointExecutionCoordinator(
      planStore: HybridCheckpointPlanStore(backend: protected),
      snapshotStore: snapshots,
      stepRunner: HybridCheckpointStepRunner(
        snapshotStore: snapshots,
        cloudRuntimeProvider: CloudRuntimeProvider(
          sendQuery: (String providerId, AiRequest request) async {
            throw StateError('Offline-only pilot attempted forbidden Cloud IO');
          },
          supportedProviders: () => const <String>['gemini'],
          isProviderAvailable: (_) => true,
          providerDisplayName: ([id]) => id ?? 'gemini',
          automaticUseAllowedForTask: (_, __) => false,
        ),
        streamInference: (request) async* {
          requests.add(request);
          if (shouldFail) {
            shouldFail = false;
            yield InferenceResponse.error('Interrupted before final output');
            return;
          }
          yield InferenceResponse.finalChunk(
            text: 'verified checkpoint ${request.checkpointId}',
            tokensGenerated: 3,
          );
        },
      ),
    );
  }

  HybridOfflineLocalPilot pilot(HybridCheckpointExecutionCoordinator source) =>
      HybridOfflineLocalPilot(
        localAuthorizer: HybridLocalSessionAuthorizer(
          backend: protected, sessions: ChatSessionStore.forTesting(db),
        ),
        coordinator: source,
        attemptJournal: HybridCheckpointAttemptJournal(backend: protected),
        isLocalReady: () async => true,
      );

  setUp(() => requests.clear());

  test('two Local steps resume from saved step without Cloud or replay',
      () async {
    await sessions.createSession('chat-a');
    final ownerId = await auth.initializeLocalOwner();
    final first = pilot(coordinator());
    await first.register(
      ownerId: ownerId,
      plan: HybridCheckpointPlan(
        executionId: 'offline-demo',
        sessionId: 'chat-a',
        instructions: const <String>['Step A', 'Step B'],
      ),
    );
    final partial = await first.resumeLocal(
      ownerId: ownerId,
      sessionId: 'chat-a',
      executionId: 'offline-demo',
      validateResult: (_, text) async => text.startsWith('verified checkpoint'),
      keepRunning: () async => requests.isEmpty,
    );
    expect(partial.isComplete, isFalse);
    expect(partial.nextCheckpoint, 2);
    expect(requests, hasLength(1));

    // New coordinator, authorizer and relay: simulate an app restart.
    final second = pilot(coordinator());
    final done = await second.resumeLocal(
      ownerId: ownerId,
      sessionId: 'chat-a',
      executionId: 'offline-demo',
      validateResult: (_, text) async => text.startsWith('verified checkpoint'),
    );
    expect(done.isComplete, isTrue);
    expect(requests, hasLength(2));
    expect(requests.every((r) =>
        r.routeDirective == InferenceRouteDirective.localOnly &&
        r.isOffline), isTrue);
    expect(requests[1].prompt, contains('verified checkpoint checkpoint-1'));
    expect(requests[1].prompt, contains('Step B'));
    expect((await sessions.listSessions()), hasLength(1));
    expect(await db.query('chat_history'), isEmpty);
  });

  test('no implicit owner, nonexistent chat, or mismatched owner enrollment',
      () async {
    final source = coordinator();
    final demo = pilot(source);
    final plan = HybridCheckpointPlan(
      executionId: 'no-owner', sessionId: 'missing',
      instructions: const <String>['Local only'],
    );
    await expectLater(
      demo.register(ownerId: 'wrong', plan: plan), throwsStateError,
    );
    expect(protected.values, isEmpty);
    final ownerId = await auth.initializeLocalOwner();
    await expectLater(
      demo.register(ownerId: ownerId, plan: plan), throwsStateError,
    );
    expect(requests, isEmpty);
    await sessions.createSession('missing');
    await expectLater(
      demo.register(ownerId: 'not-the-device-owner', plan: plan),
      throwsStateError,
    );
    expect(requests, isEmpty);
    expect(protected.values, hasLength(1)); // Owner only; no execution.
  });

  test('trashed chat blocks resume without inference, even on same device',
      () async {
    await sessions.createSession('chat-a');
    final ownerId = await auth.initializeLocalOwner();
    final demo = pilot(coordinator());
    await demo.register(
      ownerId: ownerId,
      plan: HybridCheckpointPlan(
        executionId: 'trash-test',
        sessionId: 'chat-a',
        instructions: const <String>['Only local'],
      ),
    );
    await sessions.moveToTrash('chat-a');
    await expectLater(
      demo.resumeLocal(
        ownerId: ownerId, sessionId: 'chat-a',
        executionId: 'trash-test',
        validateResult: (_, __) async => true,
      ),
      throwsStateError,
    );
    expect(requests, isEmpty);
  });

  test('unconfirmed Local result never auto-replays after restart', () async {
    await sessions.createSession('chat-a');
    final ownerId = await auth.initializeLocalOwner();
    final interrupted = pilot(coordinator(failFirst: true));
    await interrupted.register(
      ownerId: ownerId,
      plan: HybridCheckpointPlan(
        executionId: 'unknown-local-result',
        sessionId: 'chat-a',
        instructions: const <String>['Check uncertain outcome'],
      ),
    );
    await expectLater(
      interrupted.resumeLocal(
        ownerId: ownerId, sessionId: 'chat-a',
        executionId: 'unknown-local-result',
        validateResult: (_, __) async => true,
      ),
      throwsA(isA<HybridCheckpointStreamFailure>()),
    );
    expect(requests, hasLength(1));
    final restarted = pilot(coordinator());
    await expectLater(
      restarted.resumeLocal(
        ownerId: ownerId, sessionId: 'chat-a',
        executionId: 'unknown-local-result',
        validateResult: (_, __) async => true,
      ),
      throwsStateError,
    );
    expect(requests, hasLength(1));
  });
}
