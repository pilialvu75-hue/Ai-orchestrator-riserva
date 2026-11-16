import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_generation_ledger.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_preflight.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_session_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_final_build_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_frozen_source_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_source_snapshot.dart';

void main() {
  late Directory temp;
  late Directory workspace;
  late Directory archive;
  late _MemoryStorage storage;
  late WorkshopDurableBuildGenerationLedger ledger;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cantiere-session-');
    workspace = Directory(p.join(temp.path, 'workspace'))..createSync();
    archive = Directory(p.join(temp.path, 'private'));
    storage = _MemoryStorage();
    ledger = WorkshopDurableBuildGenerationLedger(storage: storage);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  WorkshopBuildRequest request(String id) => WorkshopBuildRequest(
        id: id,
        projectId: 'session-demo',
        projectPath: workspace.path,
        target: WorkshopBuildTarget.android,
        mode: WorkshopBuildExecutionMode.remote,
      );

  WorkshopDurableBuildSessionCoordinator session({
    required WorkshopDurableSourceCapture capture,
    required WorkshopDurableSessionAdvance advance,
  }) =>
      WorkshopDurableBuildSessionCoordinator(
        ledger: WorkshopDurableBuildGenerationLedger(storage: storage),
        preflight: WorkshopDurableBuildPreflight(
          ledger: WorkshopDurableBuildGenerationLedger(storage: storage),
          frozenSources: WorkshopDurableFrozenSourceStore(root: archive),
          namespace: 'test-owner',
          capture: capture,
        ),
        advance: advance,
        schedulerScope: 'test-owner',
      );

  test('concurrent new requests allocate one generation and capture once',
      () async {
    var captures = 0;
    Future<WorkshopBuildSourceSnapshot> capture(String path) async {
      captures++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return _source(path, 'void main() {}');
    }
    final first = session(
      capture: capture,
      advance: _unexpectedAdvance,
    );
    final second = session(
      capture: capture,
      advance: _unexpectedAdvance,
    );
    final reserved = first.beginNew(request('ui-a'));
    final duplicate = second.beginNew(request('ui-b'));
    final ticket = await reserved;
    await expectLater(duplicate, throwsStateError);
    expect(ticket.reservation.generation, 1);
    expect(captures, 1);
    expect((await ledger.recoverLatest(request('ui-c')))?.generation, 1);
  });

  test('restart advances same logical id without recapturing edited source',
      () async {
    final first = session(
      capture: (path) async => _source(path, 'void main() {}'),
      advance: _unexpectedAdvance,
    );
    final prepared = await first.beginNew(request('ui-a'));
    var advances = 0;
    final reopened = session(
      capture: (path) async => throw StateError('No recapture on recovery'),
      advance: ({required request, required logicalBuildId}) async {
        advances++;
        expect(logicalBuildId, prepared.reservation.buildId);
        return _step(
          request,
          logicalBuildId,
          WorkshopDurableState.waitingExternal,
          WorkshopDurableFinalBuildDisposition.waitingForRun,
        );
      },
    );
    final result = await reopened.advancePending(request('ui-b'));
    expect(result.disposition,
        WorkshopDurableFinalBuildDisposition.waitingForRun);
    expect(advances, 1);
    expect((await ledger.recoverLatest(request('ui-c')))?.state,
        WorkshopDurableGenerationState.active);
  });

  test('verified terminal checkpoint releases generation for next explicit build',
      () async {
    final actor = session(
      capture: (path) async => _source(path, 'void main() {}'),
      advance: ({required request, required logicalBuildId}) async => _step(
        request,
        logicalBuildId,
        WorkshopDurableState.completed,
        WorkshopDurableFinalBuildDisposition.completed,
      ),
    );
    final first = await actor.beginNew(request('ui-a'));
    final terminal = await actor.advancePending(request('ui-b'));
    expect(terminal.disposition,
        WorkshopDurableFinalBuildDisposition.completed);
    expect((await ledger.recoverLatest(request('ui-c')))?.state,
        WorkshopDurableGenerationState.succeeded);
    final second = await actor.beginNew(request('ui-d'));
    expect(second.reservation.generation, 2);
    expect(second.reservation.buildId, isNot(first.reservation.buildId));
  });

  test('forged completed snapshot never commits generation terminal state',
      () async {
    final actor = session(
      capture: (path) async => _source(path, 'void main() {}'),
      advance: ({required request, required logicalBuildId}) async => _step(
        request,
        'durable-v2-0000000000000000000000000000000000000000',
        WorkshopDurableState.completed,
        WorkshopDurableFinalBuildDisposition.completed,
      ),
    );
    await actor.beginNew(request('ui-a'));
    await expectLater(actor.advancePending(request('ui-b')), throwsStateError);
    expect((await ledger.recoverLatest(request('ui-c')))?.state,
        WorkshopDurableGenerationState.active);
  });

  test('retrying execution remains active and cannot allocate generation two',
      () async {
    final actor = session(
      capture: (path) async => _source(path, 'void main() {}'),
      advance: ({required request, required logicalBuildId}) async => _step(
        request,
        logicalBuildId,
        WorkshopDurableState.retrying,
        WorkshopDurableFinalBuildDisposition.retrying,
      ),
    );
    await actor.beginNew(request('ui-a'));
    await actor.advancePending(request('ui-b'));
    await expectLater(actor.beginNew(request('ui-c')), throwsStateError);
    expect((await ledger.recoverLatest(request('ui-d')))?.generation, 1);
  });

  test('independent sessions serialize one-step advances within an isolate',
      () async {
    var inFlight = 0;
    var maximum = 0;
    final started = Completer<void>();
    final resume = Completer<void>();
    Future<WorkshopDurableFinalBuildAdvance> advance({
      required WorkshopBuildRequest request,
      required String logicalBuildId,
    }) async {
      inFlight++;
      if (inFlight > maximum) maximum = inFlight;
      if (!started.isCompleted) {
        started.complete();
        await resume.future;
      }
      final outcome = _step(
        request,
        logicalBuildId,
        WorkshopDurableState.waitingExternal,
        WorkshopDurableFinalBuildDisposition.waitingForCompletion,
      );
      inFlight--;
      return outcome;
    }
    final first = session(
      capture: (path) async => _source(path, 'void main() {}'),
      advance: advance,
    );
    final second = session(
      capture: (path) async => throw StateError('No recapture'),
      advance: advance,
    );
    await first.beginNew(request('ui-a'));
    final runOne = first.advancePending(request('ui-b'));
    await started.future;
    final runTwo = second.advancePending(request('ui-c'));
    resume.complete();
    final results = await Future.wait(<Future<WorkshopDurableFinalBuildAdvance>>[
      runOne,
      runTwo,
    ]);
    expect(results, hasLength(2));
    expect(maximum, 1);
  });
}

Future<WorkshopDurableFinalBuildAdvance> _unexpectedAdvance({
  required WorkshopBuildRequest request,
  required String logicalBuildId,
}) async {
  throw StateError('No remote operations requested');
}

WorkshopBuildSourceSnapshot _source(String path, String text) {
  final bytes = Uint8List.fromList(utf8.encode(text));
  return WorkshopBuildSourceSnapshot(
    rootPath: path,
    files: <WorkshopBuildSourceFile>[
      WorkshopBuildSourceFile(relativePath: 'lib/main.dart', bytes: bytes),
    ],
    totalBytes: bytes.lengthInBytes,
  );
}

WorkshopDurableFinalBuildAdvance _step(
  WorkshopBuildRequest request,
  String logicalId,
  WorkshopDurableState state,
  WorkshopDurableFinalBuildDisposition disposition,
) {
  final now = DateTime.utc(2026, 11, 16);
  return WorkshopDurableFinalBuildAdvance(
    snapshot: WorkshopDurableProjectSnapshot(
      projectId: 'durable-final-build:$logicalId',
      correlationId: logicalId,
      state: state,
      createdAt: now,
      updatedAt: now,
      tasks: <String, WorkshopDurableTask>{
        'final-build': WorkshopDurableTask(
          taskId: 'final-build',
          capability: 'build.android',
          state: state,
          updatedAt: now,
        ),
      },
    ),
    disposition: disposition,
    buildResult: disposition == WorkshopDurableFinalBuildDisposition.completed
        ? WorkshopBuildResult(
            requestId: request.id,
            target: request.target,
            status: WorkshopBuildStatus.succeeded,
            startedAt: now,
            finishedAt: now,
            artifactPath: '/fake/verified.apk',
            testsPassed: true,
            analysisPassed: true,
            formatPassed: true,
          )
        : null,
  );
}

final class _MemoryStorage implements WorkshopDurableGenerationStorage {
  String? raw;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String value) async {
    raw = value;
    return true;
  }
}
