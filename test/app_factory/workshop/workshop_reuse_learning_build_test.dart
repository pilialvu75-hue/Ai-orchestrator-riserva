import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_source_snapshot.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _validModel = AiModel(
  id: 'gemma_2b',
  displayName: 'Gemma 2B',
  fileName: 'gemma.gguf',
  downloadUrl: 'https://example.com/model.gguf',
  version: '1.0.0',
  sizeBytes: 123,
  description: 'Test model',
  isDownloaded: true,
  localPath: '/tmp/gemma.gguf',
  validationStatus: ModelValidationStatus.validatedOk,
);

final class _FakeLocalRuntime extends LocalRuntimeProvider {
  @override
  bool supportsModel(AiModel model) => true;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {}
}

InferenceService _inferenceService() {
  return InferenceService(
    loadSelectedModel: () async => _validModel,
    loadRuntimeMode: () async => AiRuntimeMode.local,
    runtimeProvider: _FakeLocalRuntime(),
    cloudRuntimeProvider: CloudRuntimeProvider(
      sendQuery: (_, __) async => throw const ServerFailure('cloud disabled'),
      supportedProviders: () => const [],
      isProviderAvailable: (_) => false,
      providerDisplayName: ([_]) => '',
    ),
    sessionManager: RuntimeSessionManager(),
  );
}

final class _SuccessfulBuildProvider implements WorkshopBuildProvider {
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
      name: 'reuse-learning-provider',
    );
  }

  @override
  Future<WorkshopBuildResult> build(WorkshopBuildRequest request) async {
    final artifact = File(p.join(request.projectPath, 'build', 'app.apk'));
    await artifact.parent.create(recursive: true);
    await artifact.writeAsString('test artifact');
    final now = DateTime.now().toUtc();
    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.succeeded,
      startedAt: now,
      finishedAt: now,
      artifactPath: artifact.path,
      exitCode: 0,
      testsPassed: true,
      analysisPassed: true,
      formatPassed: true,
    );
  }

  @override
  Future<void> cancel(String requestId) async {}
}

void _complete(WorkshopProjectPlan plan) {
  for (final task in plan.tasks) {
    task.completed = true;
  }
  for (final phase in plan.phases) {
    phase.status = WorkshopProjectPhaseStatus.completed;
  }
  plan.status = WorkshopProjectStatus.completed;
}

void main() {
  test('successful verified build becomes reusable knowledge and source', () async {
    final temp = await Directory.systemTemp.createTemp('workshop-reuse-learn-');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final workspace = Directory(p.join(temp.path, 'workspace'));
    final snapshotRoot = p.join(temp.path, 'reuse-snapshots');
    await workspace.create(recursive: true);
    final source = File(p.join(workspace.path, 'lib', 'main.dart'));
    await source.parent.create(recursive: true);
    await source.writeAsString('void main() {}');

    final provider = _SuccessfulBuildProvider();
    final buildLab = WorkshopBuildLab(
      providers: <WorkshopBuildProvider>[provider],
    );
    addTearDown(buildLab.dispose);

    final library = WorkshopReuseLibrary();
    final snapshots = WorkshopReuseSourceSnapshotIndex();
    var libraryPersisted = false;
    var snapshotsPersisted = false;

    final bundle = WorkshopProductionLifecycleBundleFactory.createForWorkspace(
      workspaceRootPath: workspace.path,
      inferenceService: _inferenceService(),
      buildLab: buildLab,
      reuseLibrary: library,
      onReuseLibraryChanged: (_) async {
        libraryPersisted = true;
      },
      reuseSourceSnapshots: snapshots,
      onReuseSourceSnapshotsChanged: (_) async {
        snapshotsPersisted = true;
      },
      reuseSnapshotsRootPath: snapshotRoot,
    );
    addTearDown(bundle.dashboardController.dispose);

    final plan = bundle.dashboardController.startProduction(
      title: 'Invoice Pro',
      instruction: 'Build a reusable invoice application.',
      requirements: const <String>['customers', 'invoices'],
      technologies: const <String>['flutter'],
      deliverables: const <String>['invoice management'],
    );
    _complete(plan);

    final result = await WorkshopProductionTaskCoordinator(bundle: bundle)
        .buildWorkspace(
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.offlineLocal,
    );

    expect(result.succeeded, isTrue);
    expect(library.length, 1);
    expect(libraryPersisted, isTrue);

    final asset = library.assets.single;
    expect(asset.name, 'Invoice Pro');
    expect(asset.target, 'android');
    expect(asset.validationScore, 0.97);
    expect(asset.capabilities, contains('customers'));
    expect(asset.capabilities, contains('invoice management'));
    expect(asset.entryPaths, contains('lib/main.dart'));

    expect(snapshots.length, 1);
    expect(snapshotsPersisted, isTrue);
    final snapshot = snapshots.forAsset(asset.id);
    expect(snapshot, isNotNull);
    expect(snapshot!.files, contains('lib/main.dart'));
    expect(
      File(p.join(snapshot.rootPath, 'lib', 'main.dart')).existsSync(),
      isTrue,
    );
  });
}
