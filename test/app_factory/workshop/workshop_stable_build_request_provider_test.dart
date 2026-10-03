import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stable_build_request_provider.dart';

void main() {
  test('same build intent gets same provider id across UI request ids', () async {
    final inner = _CapturingProvider();
    final provider = WorkshopStableBuildRequestProvider(inner: inner);

    final first = _request(id: 'build:project:111');
    final second = _request(id: 'build:project:999');

    final firstResult = await provider.build(first);
    final firstStableId = inner.lastRequest!.id;
    final secondResult = await provider.build(second);
    final secondStableId = inner.lastRequest!.id;

    expect(firstStableId, secondStableId);
    expect(firstStableId, startsWith('build-v1-'));
    expect(firstStableId.length, 41);
    expect(firstStableId, isNot(contains(first.projectPath)));
    expect(firstResult.requestId, first.id);
    expect(secondResult.requestId, second.id);
  });

  test('semantic build changes produce a different provider id', () {
    final baseline = _request(id: 'one');
    final changedArguments = _request(
      id: 'two',
      arguments: const <String>['--dart-define=MODE=release'],
    );
    final changedProject = WorkshopBuildRequest(
      id: 'three',
      projectId: 'project-2',
      projectPath: '/workspace/project-2',
      target: WorkshopBuildTarget.android,
    );

    expect(
      WorkshopStableBuildRequestIdentity.forRequest(baseline),
      isNot(
        WorkshopStableBuildRequestIdentity.forRequest(changedArguments),
      ),
    );
    expect(
      WorkshopStableBuildRequestIdentity.forRequest(baseline),
      isNot(
        WorkshopStableBuildRequestIdentity.forRequest(changedProject),
      ),
    );
  });

  test('environment insertion order does not change stable identity', () {
    final left = _request(
      id: 'left',
      environment: const <String, String>{'B': '2', 'A': '1'},
    );
    final right = _request(
      id: 'right',
      environment: const <String, String>{'A': '1', 'B': '2'},
    );

    expect(
      WorkshopStableBuildRequestIdentity.forRequest(left),
      WorkshopStableBuildRequestIdentity.forRequest(right),
    );
  });

  test('cancel is translated to the active provider-facing request id', () async {
    final inner = _BlockingProvider();
    final provider = WorkshopStableBuildRequestProvider(inner: inner);
    final request = _request(id: 'ui-request');

    final buildFuture = provider.build(request);
    await inner.started.future;

    final expectedStable =
        WorkshopStableBuildRequestIdentity.forRequest(request);
    await provider.cancel(request.id);

    expect(inner.cancelledRequestId, expectedStable);
    inner.finish.complete();
    await buildFuture;
  });
}

WorkshopBuildRequest _request({
  required String id,
  List<String> arguments = const <String>[],
  Map<String, String> environment = const <String, String>{},
}) {
  return WorkshopBuildRequest(
    id: id,
    projectId: 'project-1',
    projectPath: '/workspace/project-1',
    target: WorkshopBuildTarget.android,
    appDisplayName: 'Demo',
    mode: WorkshopBuildExecutionMode.automatic,
    arguments: arguments,
    environment: environment,
  );
}

class _CapturingProvider implements WorkshopBuildProvider {
  WorkshopBuildRequest? lastRequest;

  @override
  WorkshopBuildExecutionMode get executionMode =>
      WorkshopBuildExecutionMode.remote;

  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) async {
    return WorkshopToolchainInfo(
      target: target,
      status: WorkshopToolchainStatus.available,
      executionMode: executionMode,
    );
  }

  @override
  Future<WorkshopBuildResult> build(WorkshopBuildRequest request) async {
    lastRequest = request;
    final now = DateTime.utc(2026, 10, 3);
    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.succeeded,
      startedAt: now,
      finishedAt: now,
      artifactPath: '/tmp/app.apk',
    );
  }

  @override
  Future<void> cancel(String requestId) async {}
}

final class _BlockingProvider extends _CapturingProvider {
  final Completer<void> started = Completer<void>();
  final Completer<void> finish = Completer<void>();
  String? cancelledRequestId;

  @override
  Future<WorkshopBuildResult> build(WorkshopBuildRequest request) async {
    lastRequest = request;
    if (!started.isCompleted) started.complete();
    await finish.future;
    final now = DateTime.utc(2026, 10, 3);
    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.cancelled,
      startedAt: now,
      finishedAt: now,
    );
  }

  @override
  Future<void> cancel(String requestId) async {
    cancelledRequestId = requestId;
  }
}
