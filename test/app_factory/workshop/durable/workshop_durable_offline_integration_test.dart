import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_generation_ledger.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_preflight.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_final_build_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_frozen_dispatch_resolver.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_frozen_source_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_github_actions_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_source_snapshot.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_github_build_monitor.dart';

/// Cross-component rehearsal; this test has no HTTP client, GitHub credentials,
/// app production factory, or real workflow dispatch.
void main() {
  late Directory root;
  late Directory workspace;
  late Directory archive;
  late File liveMain;
  late _MemoryGenerationStorage storage;
  late InMemoryWorkshopCheckpointStore checkpoints;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('durable-offline-e2e-');
    workspace = Directory(p.join(root.path, 'generated'))..createSync();
    archive = Directory(p.join(root.path, 'private-state'));
    liveMain = File(p.join(workspace.path, 'lib', 'main.dart'));
    await liveMain.parent.create(recursive: true);
    storage = _MemoryGenerationStorage();
    checkpoints = InMemoryWorkshopCheckpointStore();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  WorkshopBuildRequest request(String id) => WorkshopBuildRequest(
        id: id,
        projectId: 'generated-demo',
        projectPath: workspace.path,
        target: WorkshopBuildTarget.android,
        appDisplayName: 'Frozen Demo',
        mode: WorkshopBuildExecutionMode.remote,
      );

  WorkshopDurableBuildPreflight preflight({
    required WorkshopDurableBuildGenerationLedger ledger,
    required WorkshopDurableSourceCapture capture,
  }) =>
      WorkshopDurableBuildPreflight(
        ledger: ledger,
        frozenSources: WorkshopDurableFrozenSourceStore(root: archive),
        capture: capture,
        namespace: 'local-owner',
      );

  WorkshopDurableOrchestrator orchestrator() =>
      WorkshopDurableOrchestrator(
        store: WorkshopCheckpointDurableOrchestrationStore(
          checkpointStore: checkpoints,
        ),
        clock: () => DateTime.utc(2026, 11, 16, 20),
      );

  WorkshopDurableFinalBuildController controller({
    required WorkshopDurableOrchestrator durable,
    required _OfflineBoundaryGateway gateway,
    required String buildId,
  }) =>
      WorkshopDurableFinalBuildController(
        orchestrator: durable,
        githubCoordinator: WorkshopDurableGitHubActionsCoordinator(
          orchestrator: durable,
          gateway: gateway,
          clock: () => DateTime.utc(2026, 11, 16, 20),
        ),
        logicalBuildId: buildId,
        finalizeArtifact: ({
          required request,
          required correlationId,
          required runId,
        }) async =>
            throw StateError('Offline integration never downloads artifacts.'),
        clock: () => DateTime.utc(2026, 11, 16, 20),
      );

  test('frozen preflight, committed wait, restart and run discovery',
      () async {
    const original = 'void main() { print("frozen source"); }';
    await liveMain.writeAsString(original);

    final firstLedger = WorkshopDurableBuildGenerationLedger(storage: storage);
    final prepared = await preflight(
      ledger: firstLedger,
      capture: (path) async => _source(path, await liveMain.readAsBytes()),
    ).beginNew(request('ui-1'));
    expect(prepared.reservation.generation, 1);

    // The actual project changes before dispatch. It must never be recaptured.
    await liveMain.writeAsString('void main() { print("changed later"); }');
    final newLedger = WorkshopDurableBuildGenerationLedger(storage: storage);
    final reopened = preflight(
      ledger: newLedger,
      capture: (path) async => throw StateError(
        'Restart must not recapture the modified source folder.',
      ),
    );
    final recovered = await reopened.recoverPending(request('ui-restarted'));
    expect(recovered?.reservation.buildId, prepared.reservation.buildId);

    final fromDisk = await reopened.loadFrozenForDispatch(
      request: request('ui-2'),
      prepared: recovered!,
    );
    expect(utf8.decode(fromDisk.files.single.bytes), original);

    final durable = orchestrator();
    final gateway = _OfflineBoundaryGateway(
      orchestrator: durable,
      ledger: newLedger,
      archive: archive,
      logicalBuildId: prepared.reservation.buildId,
    );
    final first = await controller(
      durable: durable,
      gateway: gateway,
      buildId: prepared.reservation.buildId,
    ).advance(request('ui-3'));

    expect(first.disposition, WorkshopDurableFinalBuildDisposition.dispatched);
    expect(gateway.remoteCalls, 1);
    expect(gateway.sourceSeen, original);
    expect(
      gateway.correlationSeen,
      '${prepared.reservation.buildId}:attempt:1',
    );
    expect(gateway.waitWasPersistedBeforeDispatch, isTrue);

    gateway.discovered = WorkshopGitHubRun(
      id: 71,
      status: WorkshopGitHubRunStatus.inProgress,
      conclusion: WorkshopGitHubRunConclusion.unknown,
      htmlUrl: 'https://github.test/actions/runs/71',
      headBranch: 'cantiere-build/offline-fixture',
      headSha: '6666666666666666666666666666666666666666',
      createdAt: DateTime.utc(2026, 11, 16, 20),
      updatedAt: DateTime.utc(2026, 11, 16, 20, 1),
    );

    // Recreate all in-memory drivers; retain only checkpoint and archive data.
    final resumedOrchestrator = orchestrator();
    final secondGateway = _OfflineBoundaryGateway(
      orchestrator: resumedOrchestrator,
      ledger: WorkshopDurableBuildGenerationLedger(storage: storage),
      archive: archive,
      logicalBuildId: prepared.reservation.buildId,
    )..discovered = gateway.discovered;
    final second = await controller(
      durable: resumedOrchestrator,
      gateway: secondGateway,
      buildId: prepared.reservation.buildId,
    ).advance(request('ui-4'));

    expect(second.disposition,
        WorkshopDurableFinalBuildDisposition.waitingForCompletion);
    expect(secondGateway.remoteCalls, 0);
    expect(secondGateway.discoveryCalls, 1);
    final saved = await resumedOrchestrator.loadProject(
      'durable-final-build:${prepared.reservation.buildId}',
    );
    expect(saved!.tasks['final-build']!.attemptsStarted, 1);
    expect(
      saved.tasks['final-build']!.externalWait?.eventType,
      WorkshopDurableEventTypes.ciCompleted,
    );
  });

  test('missing archive is never replaced with fresh source or dispatched',
      () async {
    await liveMain.writeAsString('void main() { print("original"); }');
    final ledger = WorkshopDurableBuildGenerationLedger(storage: storage);
    final prepared = await preflight(
      ledger: ledger,
      capture: (path) async => _source(path, await liveMain.readAsBytes()),
    ).beginNew(request('ui-initial'));
    await File(p.join(archive.path, '${prepared.sourceHandle.key}.avxf'))
        .delete();
    await liveMain.writeAsString('void main() { print("attacker change"); }');

    final durable = orchestrator();
    final gateway = _OfflineBoundaryGateway(
      orchestrator: durable,
      ledger: ledger,
      archive: archive,
      logicalBuildId: prepared.reservation.buildId,
    );
    // A fake gateway intentionally models the remote side effect only after
    // source resolution; a missing frozen archive cannot reach that point.
    final result = await controller(
      durable: durable,
      gateway: gateway,
      buildId: prepared.reservation.buildId,
    ).advance(request('ui-after-missing-archive'));
    expect(result.disposition, WorkshopDurableFinalBuildDisposition.dispatched);
    expect(gateway.remoteCalls, 0);
    expect(gateway.sourceSeen, isNull);
    expect(
      (await ledger.recoverLatest(request('ui-read')))?.generation,
      prepared.reservation.generation,
    );
  });
}

WorkshopBuildSourceSnapshot _source(String path, Uint8List bytes) =>
    WorkshopBuildSourceSnapshot(
      rootPath: path,
      files: <WorkshopBuildSourceFile>[
        WorkshopBuildSourceFile(relativePath: 'lib/main.dart', bytes: bytes),
      ],
      totalBytes: bytes.lengthInBytes,
    );

final class _MemoryGenerationStorage implements WorkshopDurableGenerationStorage {
  String? saved;

  @override
  Future<String?> read() async => saved;

  @override
  Future<bool> write(String value) async {
    saved = value;
    return true;
  }
}

/// Simulates the GitHub boundary without HTTP. A call is counted as a remote
/// side effect only after the ledger-bound frozen source has been recovered.
final class _OfflineBoundaryGateway
    implements WorkshopDurableGitHubActionsGateway {
  _OfflineBoundaryGateway({
    required this.orchestrator,
    required WorkshopDurableBuildGenerationLedger ledger,
    required Directory archive,
    required this.logicalBuildId,
  }) : resolver = WorkshopDurableFrozenDispatchResolver(
          ledger: ledger,
          frozenStore: WorkshopDurableFrozenSourceStore(root: archive),
          namespace: 'local-owner',
        );

  final WorkshopDurableOrchestrator orchestrator;
  final WorkshopDurableFrozenDispatchResolver resolver;
  final String logicalBuildId;

  int remoteCalls = 0;
  int discoveryCalls = 0;
  String? sourceSeen;
  String? correlationSeen;
  bool waitWasPersistedBeforeDispatch = false;
  WorkshopGitHubRun? discovered;

  @override
  Future<WorkshopDurableGitHubDispatchOutcome> dispatch({
    required WorkshopBuildRequest request,
    required String correlationId,
  }) async {
    final project = await orchestrator.loadProject(
      'durable-final-build:$logicalBuildId',
    );
    waitWasPersistedBeforeDispatch =
        project?.tasks['final-build']?.state ==
            WorkshopDurableState.waitingExternal &&
        project?.tasks['final-build']?.externalWait?.externalId ==
            correlationId;
    if (!waitWasPersistedBeforeDispatch) {
      throw StateError('Remote dispatch without durable wait checkpoint.');
    }

    final frozen = await resolver.resolve(
      request: request,
      correlationId: correlationId,
    );
    sourceSeen = utf8.decode(frozen.files.single.bytes);
    correlationSeen = correlationId;
    remoteCalls++;
    return WorkshopDurableGitHubDispatchOutcome.accepted;
  }

  @override
  Future<WorkshopGitHubRun?> discoverRun({
    required WorkshopBuildRequest request,
    required String correlationId,
  }) async {
    discoveryCalls++;
    return discovered;
  }

  @override
  Future<WorkshopGitHubRun?> getRun(int runId) async => null;

  @override
  Future<List<WorkshopGitHubArtifact>> getArtifacts(int runId) async =>
      const <WorkshopGitHubArtifact>[];
}
