import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_generation_ledger.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_terminal_generation_reconciler.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_background_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_source_snapshot.dart';

void main() {
  group('WorkshopDurableTerminalGenerationReconciler', () {
    late _MemoryGenerationStorage generationStorage;
    late WorkshopDurableBuildGenerationLedger ledger;
    late InMemoryWorkshopCheckpointStore checkpointStorage;
    late WorkshopDurableOrchestrator orchestrator;
    late WorkshopDurableTerminalGenerationReconciler reconciler;
    late WorkshopBuildRequest request;
    late WorkshopDurableBuildReservation reservation;
    final now = DateTime.utc(2026, 11, 17, 8);

    setUp(() async {
      generationStorage = _MemoryGenerationStorage();
      ledger = WorkshopDurableBuildGenerationLedger(
        storage: generationStorage,
      );
      checkpointStorage = InMemoryWorkshopCheckpointStore();
      final persisted = WorkshopCheckpointDurableOrchestrationStore(
        checkpointStore: checkpointStorage,
      );
      orchestrator = WorkshopDurableOrchestrator(
        store: persisted,
        clock: () => now,
      );
      reconciler = WorkshopDurableTerminalGenerationReconciler(
        ledger: ledger,
        orchestrationStore: WorkshopCheckpointDurableOrchestrationStore(
          checkpointStore: checkpointStorage,
        ),
      );
      request = _request('ui-first');
      reservation = await ledger.reserveNew(
        request: request,
        source: _source(),
      );
    });

    String getProjectId() => 'durable-final-build:${reservation.buildId}';

    Future<void> prepare({String? correlationId}) async {
      await orchestrator.createProject(
        projectId: getProjectId(),
        correlationId: correlationId ?? reservation.buildId,
        tasks: <WorkshopDurableTask>[
          WorkshopDurableTask(
            taskId: 'final-build',
            capability: 'build.android',
            state: WorkshopDurableState.created,
            retryPolicy: const WorkshopDurableRetryPolicy(maxAttempts: 1),
            updatedAt: now,
            completionCriterionIds: const <String>[
              'artifact.provenance_verified',
              'artifact.hash_verified',
              'artifact.validation_verified',
            ],
          ),
        ],
      );
      await orchestrator.markProjectReady(getProjectId());
    }

    Future<void> start() async {
      await orchestrator.startTask(
        projectId: getProjectId(),
        taskId: 'final-build',
        operationIdempotencyKey: 'local-proof-attempt-1',
      );
    }

    Future<void> complete() async {
      await prepare();
      await start();
      await orchestrator.completeTask(
        projectId: getProjectId(),
        taskId: 'final-build',
        artifactIds: const <String>['local-apk:/private/app/verified.apk'],
      );
    }

    Future<WorkshopDurableBuildReservation?> reconcile([String? buildId]) =>
        reconciler.reconcile(
          request: _request('ui-after-restart'),
          expectedBuildId: buildId ?? reservation.buildId,
        );

    test('terminal checkpoint commits once and survives process reconstruction',
        () async {
      await complete();
      expect((await ledger.recoverLatest(request))!.state,
          WorkshopDurableGenerationState.active);
      final committed = await reconcile();
      expect(committed!.state, WorkshopDurableGenerationState.succeeded);

      final afterRestart = WorkshopDurableTerminalGenerationReconciler(
        ledger: WorkshopDurableBuildGenerationLedger(
          storage: generationStorage,
        ),
        orchestrationStore: WorkshopCheckpointDurableOrchestrationStore(
          checkpointStore: checkpointStorage,
        ),
      );
      final replay = await afterRestart.reconcile(
        request: _request('ui-restart'),
        expectedBuildId: reservation.buildId,
      );
      expect(replay!.generation, 1);
      expect(replay.state, WorkshopDurableGenerationState.succeeded);
      final next = await ledger.reserveNew(
        request: _request('ui-explicit-new-build'),
        source: _source(),
      );
      expect(next.generation, 2);
      expect(next.buildId, isNot(reservation.buildId));
    });

    test('nonterminal checkpoint never releases active generation', () async {
      await prepare();
      await start();
      expect(await reconcile(), isNull);
      expect((await ledger.recoverLatest(request))!.state,
          WorkshopDurableGenerationState.active);
      await expectLater(
        ledger.reserveNew(request: request, source: _source()),
        throwsStateError,
      );
    });

    test('missing checkpoint fails closed', () async {
      await expectLater(reconcile(), throwsStateError);
      expect((await ledger.recoverLatest(request))!.state,
          WorkshopDurableGenerationState.active);
    });

    test('wrong checkpoint correlation fails closed', () async {
      await prepare(correlationId: 'different-generation');
      await expectLater(reconcile(), throwsStateError);
      expect((await ledger.recoverLatest(request))!.state,
          WorkshopDurableGenerationState.active);
    });

    test('completed checkpoint without APK evidence cannot release generation',
        () async {
      await prepare();
      await start();
      await orchestrator.completeTask(
        projectId: getProjectId(),
        taskId: 'final-build',
      );
      await expectLater(reconcile(), throwsStateError);
      expect((await ledger.recoverLatest(request))!.state,
          WorkshopDurableGenerationState.active);
    });

    test('failed checkpoint persists terminal failure without false success',
        () async {
      await prepare();
      await start();
      await orchestrator.failTask(
        projectId: getProjectId(),
        taskId: 'final-build',
        failureClass: WorkshopDurableFailureClass.codeError,
      );
      expect((await reconcile())!.state,
          WorkshopDurableGenerationState.failed);
    });

    test('failed ledger write is retryable after persisted terminal checkpoint',
        () async {
      await complete();
      generationStorage.rejectWrites = true;
      await expectLater(reconcile(), throwsStateError);
      expect((await ledger.recoverLatest(request))!.state,
          WorkshopDurableGenerationState.active);
      generationStorage.rejectWrites = false;
      expect((await reconcile())!.state,
          WorkshopDurableGenerationState.succeeded);
    });

    test('late callback cannot commit an earlier generation', () async {
      await complete();
      await reconcile();
      final next = await ledger.reserveNew(
        request: _request('ui-second'),
        source: _source(),
      );
      expect(next.generation, 2);
      await expectLater(reconcile(reservation.buildId), throwsStateError);
      expect((await ledger.recoverLatest(request))!.buildId, next.buildId);
      expect((await ledger.recoverLatest(request))!.state,
          WorkshopDurableGenerationState.active);
    });
  });
}

WorkshopBuildRequest _request(String id) => WorkshopBuildRequest(
      id: id,
      projectId: 'durable-demo',
      projectPath: '/workspace/durable-demo',
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.remote,
    );

WorkshopBuildSourceSnapshot _source() {
  final bytes = Uint8List.fromList(utf8.encode('void main() {}'));
  return WorkshopBuildSourceSnapshot(
    rootPath: '/workspace/durable-demo',
    files: <WorkshopBuildSourceFile>[
      WorkshopBuildSourceFile(
        relativePath: 'lib/main.dart',
        bytes: bytes,
      ),
    ],
    totalBytes: bytes.lengthInBytes,
  );
}

final class _MemoryGenerationStorage
    implements WorkshopDurableGenerationStorage {
  String? value;
  bool rejectWrites = false;

  @override
  Future<String?> read() async => value;

  @override
  Future<bool> write(String input) async {
    if (rejectWrites) return false;
    value = input;
    return true;
  }
}
