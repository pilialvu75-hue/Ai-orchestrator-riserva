import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production workspace composition prefers remote build provider', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'workshop-production-build-routing-',
    );
    addTearDown(() async => workspace.delete(recursive: true));

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

    final bundle = WorkshopProductionLifecycleBundleFactory.createForWorkspace(
      workspaceRootPath: workspace.path,
      buildProviders: <WorkshopBuildProvider>[local, remote],
    );

    final result = await bundle.dashboardController.buildLab.build(
      _request(workspace.path),
    );

    expect(result.message, 'remote');
    expect(remote.buildCalls, 1);
    expect(local.buildCalls, 0);

    bundle.dashboardController.dispose();
  });

  test('production workspace composition falls back to offline local', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'workshop-production-build-fallback-',
    );
    addTearDown(() async => workspace.delete(recursive: true));

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

    final bundle = WorkshopProductionLifecycleBundleFactory.createForWorkspace(
      workspaceRootPath: workspace.path,
      buildProviders: <WorkshopBuildProvider>[local, remote],
    );

    final result = await bundle.dashboardController.buildLab.build(
      _request(workspace.path),
    );

    expect(result.message, 'local');
    expect(remote.buildCalls, 0);
    expect(local.buildCalls, 1);

    bundle.dashboardController.dispose();
  });
}

WorkshopBuildRequest _request(String workspacePath) {
  return WorkshopBuildRequest(
    id: 'production-build-1',
    projectId: 'project-1',
    projectPath: workspacePath,
    target: WorkshopBuildTarget.android,
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
