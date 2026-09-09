import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
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
      inferenceService: _buildInferenceService(),
      buildProviders: <WorkshopBuildProvider>[local, remote],
    );
    addTearDown(bundle.dashboardController.dispose);

    final result = await bundle.dashboardController.buildLab.build(
      _request(workspace.path),
    );

    expect(result.message, 'remote');
    expect(remote.buildCalls, 1);
    expect(local.buildCalls, 0);
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
      inferenceService: _buildInferenceService(),
      buildProviders: <WorkshopBuildProvider>[local, remote],
    );
    addTearDown(bundle.dashboardController.dispose);

    final result = await bundle.dashboardController.buildLab.build(
      _request(workspace.path),
    );

    expect(result.message, 'local');
    expect(remote.buildCalls, 0);
    expect(local.buildCalls, 1);
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
