import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
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

InferenceService _buildInferenceService() {
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
      inferenceService: _buildInferenceService(),
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
    final provider = _CapturingBuildProvider();
    final buildLab = WorkshopBuildLab(
      providers: <WorkshopBuildProvider>[provider],
    );
    addTearDown(buildLab.dispose);

    final bundle = WorkshopProductionLifecycleBundleFactory.createForWorkspace(
      workspaceRootPath: Directory.systemTemp.path,
      inferenceService: _buildInferenceService(),
      buildLab: buildLab,
    );
    addTearDown(bundle.dashboardController.dispose);

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
  });
}
