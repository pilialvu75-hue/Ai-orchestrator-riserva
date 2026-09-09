import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_provider_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic build prefers remote provider even when local is supplied first', () async {
    final local = _FakeBuildProvider(
      mode: WorkshopBuildExecutionMode.offlineLocal,
      available: true,
      label: 'local',
    );
    final remote = _FakeBuildProvider(
      mode: WorkshopBuildExecutionMode.remote,
      available: true,
      label: 'remote',
    );

    final lab = WorkshopBuildLab(
      providers: WorkshopBuildProviderPolicy.remotePreferred(
        <WorkshopBuildProvider>[local, remote],
      ),
    );

    final result = await lab.build(_request());

    expect(result.message, 'remote');
    expect(remote.buildCalls, 1);
    expect(local.buildCalls, 0);

    await lab.dispose();
  });

  test('automatic build falls back to local when remote is unavailable', () async {
    final local = _FakeBuildProvider(
      mode: WorkshopBuildExecutionMode.offlineLocal,
      available: true,
      label: 'local',
    );
    final remote = _FakeBuildProvider(
      mode: WorkshopBuildExecutionMode.remote,
      available: false,
      label: 'remote',
    );

    final lab = WorkshopBuildLab(
      providers: WorkshopBuildProviderPolicy.remotePreferred(
        <WorkshopBuildProvider>[local, remote],
      ),
    );

    final result = await lab.build(_request());

    expect(result.message, 'local');
    expect(remote.buildCalls, 0);
    expect(local.buildCalls, 1);

    await lab.dispose();
  });

  test('explicit offlineLocal mode never selects the remote provider', () async {
    final local = _FakeBuildProvider(
      mode: WorkshopBuildExecutionMode.offlineLocal,
      available: true,
      label: 'local',
    );
    final remote = _FakeBuildProvider(
      mode: WorkshopBuildExecutionMode.remote,
      available: true,
      label: 'remote',
    );

    final lab = WorkshopBuildLab(
      providers: WorkshopBuildProviderPolicy.remotePreferred(
        <WorkshopBuildProvider>[local, remote],
      ),
    );

    final result = await lab.build(
      _request(mode: WorkshopBuildExecutionMode.offlineLocal),
    );

    expect(result.message, 'local');
    expect(remote.buildCalls, 0);
    expect(local.buildCalls, 1);

    await lab.dispose();
  });
}

WorkshopBuildRequest _request({
  WorkshopBuildExecutionMode mode = WorkshopBuildExecutionMode.automatic,
}) {
  return WorkshopBuildRequest(
    id: 'build-1',
    projectId: 'project-1',
    projectPath: '/tmp/project-1',
    target: WorkshopBuildTarget.android,
    mode: mode,
  );
}

final class _FakeBuildProvider implements WorkshopBuildProvider {
  _FakeBuildProvider({
    required this.mode,
    required this.available,
    required this.label,
  });

  final WorkshopBuildExecutionMode mode;
  final bool available;
  final String label;

  int buildCalls = 0;

  @override
  WorkshopBuildExecutionMode get executionMode => mode;

  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) async {
    return WorkshopToolchainInfo(
      target: target,
      status: available
          ? WorkshopToolchainStatus.available
          : WorkshopToolchainStatus.unavailable,
      executionMode: mode,
      name: label,
    );
  }

  @override
  Future<WorkshopBuildResult> build(
    WorkshopBuildRequest request,
  ) async {
    buildCalls += 1;
    final now = DateTime.now();

    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.succeeded,
      startedAt: now,
      finishedAt: now,
      message: label,
    );
  }

  @override
  Future<void> cancel(String requestId) async {}
}
