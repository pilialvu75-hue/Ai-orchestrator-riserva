import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:flutter_test/flutter_test.dart';

final class _CapturingBuildProvider implements WorkshopBuildProvider {
  WorkshopBuildRequest? request;

  @override
  WorkshopBuildExecutionMode get executionMode =>
      WorkshopBuildExecutionMode.offlineLocal;

  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) async {
    return WorkshopToolchainInfo(
      target: target,
      status: WorkshopToolchainStatus.available,
      executionMode: executionMode,
      name: 'test provider',
    );
  }

  @override
  Future<WorkshopBuildResult> build(WorkshopBuildRequest request) async {
    this.request = request;
    final now = DateTime.now();
    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.succeeded,
      startedAt: now,
      finishedAt: now,
      artifactPath: '${request.projectPath}/build/app.apk',
      exitCode: 0,
      testsPassed: true,
      analysisPassed: true,
      formatPassed: true,
    );
  }

  @override
  Future<void> cancel(String requestId) async {}
}

void main() {
  test('production build targets the exact authoritative Cantiere workspace',
      () async {
    final workspace = await Directory.systemTemp.createTemp(
      'workshop-production-build-',
    );
    addTearDown(() async {
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    });

    final provider = _CapturingBuildProvider();
    final buildLab = WorkshopBuildLab(
      providers: <WorkshopBuildProvider>[provider],
    );
    addTearDown(buildLab.dispose);

    final bundle = WorkshopProductionLifecycleBundleFactory.createForWorkspace(
      workspaceRootPath: '  ${workspace.path}  ',
      buildLab: buildLab,
    );
    addTearDown(bundle.dashboardController.dispose);

    final coordinator = WorkshopProductionTaskCoordinator(bundle: bundle);

    final result = await coordinator.buildWorkspace(
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.offlineLocal,
    );

    expect(result.succeeded, isTrue);
    expect(provider.request, isNotNull);
    expect(provider.request!.projectPath, workspace.path);
    expect(bundle.workspaceRootPath, workspace.path);
  });

  test('generic production bundle cannot invent a build workspace', () {
    final workspace = Directory.systemTemp;
    final bundle = WorkshopProductionLifecycleBundleFactory.createForWorkspace(
      workspaceRootPath: workspace.path,
    );

    final generic = WorkshopProductionLifecycleBundle(
      dashboardController: bundle.dashboardController,
      preflight: bundle.preflight,
      taskLifecycle: bundle.taskLifecycle,
      projectExecutor: bundle.projectExecutor,
    );

    final coordinator = WorkshopProductionTaskCoordinator(bundle: generic);

    expect(
      () => coordinator.buildWorkspace(target: WorkshopBuildTarget.android),
      throwsA(isA<StateError>()),
    );

    bundle.dashboardController.dispose();
  });
}
