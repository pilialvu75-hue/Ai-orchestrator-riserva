import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_final_build_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_github_actions_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_github_build_monitor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stable_build_request_provider.dart';

void main() {
  test('fresh controller resumes persisted GitHub run without redispatch',
      () async {
    final checkpoints = InMemoryWorkshopCheckpointStore();
    final gateway = _FakeGateway();
    final firstRequest = _request('ui-build-1');
    final logicalId =
        WorkshopStableBuildRequestIdentity.forRequest(firstRequest);
    String? finalizedCorrelation;
    int? finalizedRunId;

    var controller = _controller(
      checkpoints: checkpoints,
      gateway: gateway,
      finalize: ({required request, required correlationId, required runId}) async {
        finalizedCorrelation = correlationId;
        finalizedRunId = runId;
        return _success(request, '/tmp/verified-app.apk');
      },
    );

    final dispatched = await controller.advance(firstRequest);
    expect(
      dispatched.disposition,
      WorkshopDurableFinalBuildDisposition.dispatched,
    );
    expect(gateway.dispatchCalls, 1);
    expect(gateway.lastDispatchCorrelation, '$logicalId:attempt:1');

    gateway.discoveredRun = _run(
      id: 41,
      status: WorkshopGitHubRunStatus.inProgress,
    );

    // New instances model process death. Only the checkpoint store survives.
    controller = _controller(
      checkpoints: checkpoints,
      gateway: gateway,
      finalize: ({required request, required correlationId, required runId}) async {
        finalizedCorrelation = correlationId;
        finalizedRunId = runId;
        return _success(request, '/tmp/verified-app.apk');
      },
    );
    final recovered = await controller.advance(_request('ui-build-2'));
    expect(
      recovered.disposition,
      WorkshopDurableFinalBuildDisposition.waitingForCompletion,
    );
    expect(gateway.dispatchCalls, 1);
    expect(gateway.discoverCalls, 1);

    gateway.observedRun = _run(
      id: 41,
      status: WorkshopGitHubRunStatus.completed,
      conclusion: WorkshopGitHubRunConclusion.success,
    );
    gateway.artifacts = const <WorkshopGitHubArtifact>[
      WorkshopGitHubArtifact(
        id: 901,
        name: 'cantiere-android-demo',
        archiveDownloadUrl: 'https://github.test/artifact/901',
        sizeInBytes: 100,
        expired: false,
      ),
    ];

    controller = _controller(
      checkpoints: checkpoints,
      gateway: gateway,
      finalize: ({required request, required correlationId, required runId}) async {
        finalizedCorrelation = correlationId;
        finalizedRunId = runId;
        return _success(request, '/tmp/verified-app.apk');
      },
    );
    final completed = await controller.advance(_request('ui-build-3'));

    expect(
      completed.disposition,
      WorkshopDurableFinalBuildDisposition.completed,
    );
    expect(completed.buildResult?.succeeded, isTrue);
    expect(finalizedCorrelation, '$logicalId:attempt:1');
    expect(finalizedRunId, 41);
    expect(gateway.dispatchCalls, 1);

    // A further process restart reconstructs the verified terminal result from
    // durable artifact metadata; it does not touch GitHub again.
    final terminal = await _controller(
      checkpoints: checkpoints,
      gateway: gateway,
      finalize: ({required request, required correlationId, required runId}) async {
        fail('terminal durable build must not finalize twice');
      },
    ).advance(_request('ui-build-4'));
    expect(
      terminal.disposition,
      WorkshopDurableFinalBuildDisposition.completed,
    );
    expect(terminal.buildResult?.artifactPath, '/tmp/verified-app.apk');
    expect(gateway.dispatchCalls, 1);
  });

  test('retry gets a new persisted attempt correlation', () async {
    final checkpoints = InMemoryWorkshopCheckpointStore();
    final gateway = _FakeGateway()
      ..dispatchOutcomes.add(
        const WorkshopDurableGitHubDispatchOutcome(
          disposition: WorkshopDurableGitHubDispatchDisposition.rejected,
          failureClass: WorkshopDurableFailureClass.providerUnavailable,
          message: 'temporary provider rejection',
        ),
      )
      ..dispatchOutcomes.add(WorkshopDurableGitHubDispatchOutcome.accepted);
    final request = _request('first-ui-id');
    final logicalId = WorkshopStableBuildRequestIdentity.forRequest(request);
    final controller = _controller(
      checkpoints: checkpoints,
      gateway: gateway,
      finalize: ({required request, required correlationId, required runId}) async {
        fail('finalizer should not run in this test');
      },
    );

    final first = await controller.advance(request);
    expect(first.disposition, WorkshopDurableFinalBuildDisposition.retrying);
    expect(gateway.dispatchCorrelations, <String>['$logicalId:attempt:1']);

    final second = await controller.advance(_request('second-ui-id'));
    expect(second.disposition, WorkshopDurableFinalBuildDisposition.dispatched);
    expect(
      gateway.dispatchCorrelations,
      <String>[
        '$logicalId:attempt:1',
        '$logicalId:attempt:2',
      ],
    );
  });

  test('transient artifact finalization failure does not redispatch GitHub',
      () async {
    final checkpoints = InMemoryWorkshopCheckpointStore();
    final gateway = _FakeGateway();
    var finalizeCalls = 0;
    final controller = _controller(
      checkpoints: checkpoints,
      gateway: gateway,
      finalize: ({required request, required correlationId, required runId}) async {
        finalizeCalls += 1;
        throw const WorkshopDurableGitHubGatewayException(
          'artifact download unavailable',
          failureClass: WorkshopDurableFailureClass.providerUnavailable,
          definitive: false,
        );
      },
    );

    await controller.advance(_request('ui-1'));
    gateway.discoveredRun = _run(
      id: 52,
      status: WorkshopGitHubRunStatus.inProgress,
    );
    await controller.advance(_request('ui-2'));
    gateway.observedRun = _run(
      id: 52,
      status: WorkshopGitHubRunStatus.completed,
      conclusion: WorkshopGitHubRunConclusion.success,
    );

    final firstFinalize = await controller.advance(_request('ui-3'));
    expect(
      firstFinalize.disposition,
      WorkshopDurableFinalBuildDisposition.finalizing,
    );
    expect(finalizeCalls, 1);
    expect(gateway.dispatchCalls, 1);

    final secondFinalize = await controller.advance(_request('ui-4'));
    expect(
      secondFinalize.disposition,
      WorkshopDurableFinalBuildDisposition.finalizing,
    );
    expect(finalizeCalls, 2);
    expect(gateway.dispatchCalls, 1);
  });

  test('definitive invalid artifact closes durable build as failed', () async {
    final checkpoints = InMemoryWorkshopCheckpointStore();
    final gateway = _FakeGateway();
    final controller = _controller(
      checkpoints: checkpoints,
      gateway: gateway,
      finalize: ({required request, required correlationId, required runId}) async {
        throw const WorkshopDurableGitHubGatewayException(
          'artifact provenance mismatch',
          failureClass: WorkshopDurableFailureClass.invalidArtifact,
          definitive: true,
        );
      },
    );

    await controller.advance(_request('ui-1'));
    gateway.discoveredRun = _run(
      id: 63,
      status: WorkshopGitHubRunStatus.inProgress,
    );
    await controller.advance(_request('ui-2'));
    gateway.observedRun = _run(
      id: 63,
      status: WorkshopGitHubRunStatus.completed,
      conclusion: WorkshopGitHubRunConclusion.success,
    );

    final failed = await controller.advance(_request('ui-3'));
    expect(failed.disposition, WorkshopDurableFinalBuildDisposition.failed);
    expect(failed.buildResult?.status, WorkshopBuildStatus.failed);
    expect(gateway.dispatchCalls, 1);
  });
}

WorkshopDurableFinalBuildController _controller({
  required WorkshopCheckpointStore checkpoints,
  required _FakeGateway gateway,
  required WorkshopDurableArtifactFinalize finalize,
}) {
  final orchestrator = WorkshopDurableOrchestrator(
    store: WorkshopCheckpointDurableOrchestrationStore(
      checkpointStore: checkpoints,
    ),
    clock: () => DateTime.utc(2026, 10, 3, 20),
  );
  return WorkshopDurableFinalBuildController(
    orchestrator: orchestrator,
    githubCoordinator: WorkshopDurableGitHubActionsCoordinator(
      orchestrator: orchestrator,
      gateway: gateway,
      clock: () => DateTime.utc(2026, 10, 3, 20),
    ),
    finalizeArtifact: finalize,
    clock: () => DateTime.utc(2026, 10, 3, 20),
  );
}

WorkshopBuildRequest _request(String id) => WorkshopBuildRequest(
      id: id,
      projectId: 'project-1',
      projectPath: '/workspace/project-1',
      target: WorkshopBuildTarget.android,
      appDisplayName: 'Durable Demo',
      mode: WorkshopBuildExecutionMode.remote,
    );

WorkshopBuildResult _success(WorkshopBuildRequest request, String path) {
  final now = DateTime.utc(2026, 10, 3, 20);
  return WorkshopBuildResult(
    requestId: request.id,
    target: request.target,
    status: WorkshopBuildStatus.succeeded,
    startedAt: now,
    finishedAt: now,
    artifactPath: path,
    testsPassed: true,
    analysisPassed: true,
    formatPassed: true,
  );
}

WorkshopGitHubRun _run({
  required int id,
  required WorkshopGitHubRunStatus status,
  WorkshopGitHubRunConclusion conclusion = WorkshopGitHubRunConclusion.unknown,
}) {
  return WorkshopGitHubRun(
    id: id,
    status: status,
    conclusion: conclusion,
    htmlUrl: 'https://github.test/actions/runs/$id',
    headBranch: 'cantiere-build/test',
    headSha: '6666666666666666666666666666666666666666',
    createdAt: DateTime.utc(2026, 10, 3, 20),
    updatedAt: DateTime.utc(2026, 10, 3, 20, 1),
  );
}

final class _FakeGateway implements WorkshopDurableGitHubActionsGateway {
  final List<WorkshopDurableGitHubDispatchOutcome> dispatchOutcomes =
      <WorkshopDurableGitHubDispatchOutcome>[];
  final List<String> dispatchCorrelations = <String>[];
  WorkshopGitHubRun? discoveredRun;
  WorkshopGitHubRun? observedRun;
  List<WorkshopGitHubArtifact> artifacts = const <WorkshopGitHubArtifact>[];
  int dispatchCalls = 0;
  int discoverCalls = 0;

  String? get lastDispatchCorrelation =>
      dispatchCorrelations.isEmpty ? null : dispatchCorrelations.last;

  @override
  Future<WorkshopDurableGitHubDispatchOutcome> dispatch({
    required WorkshopBuildRequest request,
    required String correlationId,
  }) async {
    dispatchCalls += 1;
    dispatchCorrelations.add(correlationId);
    if (dispatchOutcomes.isNotEmpty) {
      return dispatchOutcomes.removeAt(0);
    }
    return WorkshopDurableGitHubDispatchOutcome.accepted;
  }

  @override
  Future<WorkshopGitHubRun?> discoverRun({
    required WorkshopBuildRequest request,
    required String correlationId,
  }) async {
    discoverCalls += 1;
    return discoveredRun;
  }

  @override
  Future<WorkshopGitHubRun?> getRun(int runId) async => observedRun;

  @override
  Future<List<WorkshopGitHubArtifact>> getArtifacts(int runId) async => artifacts;
}
