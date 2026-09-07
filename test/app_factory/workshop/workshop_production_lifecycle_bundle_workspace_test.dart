import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
  test('production bundle keeps the exact real workspace for verification', () {
    final workspacePath = Directory.systemTemp.path;

    final bundle = WorkshopProductionLifecycleBundleFactory.createForWorkspace(
      workspaceRootPath: '  $workspacePath  ',
      inferenceService: _buildInferenceService(),
    );
    addTearDown(bundle.dashboardController.dispose);

    expect(bundle.workspaceRootPath, workspacePath);
  });
}
