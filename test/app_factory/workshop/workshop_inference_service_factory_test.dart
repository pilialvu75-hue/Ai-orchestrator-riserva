import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_service_factory.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/error/failures.dart';

void main() {
  group('WorkshopInferenceServiceFactory', () {
    test('resolves the assigned Workshop model without Assistant selection', () async {
      final assistant = _model(
        id: 'phi3_5_mini',
        path: '/models/phi3.gguf',
      );
      final workshop = _model(
        id: 'starcoder_catalogue',
        runtimeModelId: 'starcoder2_3b',
        path: '/models/starcoder2.gguf',
      );

      final repository = _FakeLocalAiRepository(
        <AiModel>[assistant, workshop],
      );

      final resolved =
          await WorkshopInferenceServiceFactory.resolveInstalledModel(
        modelId: 'starcoder2_3b',
        repository: repository,
      );

      expect(resolved, same(workshop));
      expect(resolved, isNot(same(assistant)));
      expect(resolved?.localPath, '/models/starcoder2.gguf');
    });

    test('returns null when the assigned Workshop model is not installed', () async {
      final repository = _FakeLocalAiRepository(
        <AiModel>[
          _model(
            id: 'phi3_5_mini',
            path: '/models/phi3.gguf',
          ),
        ],
      );

      final resolved =
          await WorkshopInferenceServiceFactory.resolveInstalledModel(
        modelId: 'starcoder2_3b',
        repository: repository,
      );

      expect(resolved, isNull);
    });
  });
}

AiModel _model({
  required String id,
  required String path,
  String? runtimeModelId,
}) {
  return AiModel(
    id: id,
    displayName: id,
    fileName: '$id.gguf',
    downloadUrl: 'https://example.invalid/$id.gguf',
    version: '1.0.0',
    sizeBytes: 1024,
    description: 'test model',
    isDownloaded: true,
    localPath: path,
    validationStatus: ModelValidationStatus.validatedOk,
    runtimeModelId: runtimeModelId,
  );
}

final class _FakeLocalAiRepository implements LocalAiRepository {
  _FakeLocalAiRepository(this.models);

  final List<AiModel> models;

  @override
  Future<Either<Failure, List<AiModel>>> getAvailableModels() async =>
      Right<Failure, List<AiModel>>(models);

  @override
  Future<Either<Failure, AiModel>> downloadModel(
    AiModel model, {
    void Function(double progress)? onProgress,
  }) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, AiModel>> downloadModelFromUrl(
    String url, {
    required String modelId,
    required String displayName,
    required String fileName,
    void Function(double progress)? onProgress,
  }) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, AiModel?>> importLocalModel({
    String? existingModelId,
  }) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, void>> cancelDownload(String modelId) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, void>> deleteModel(String modelId) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, List<AiModel>>> checkForUpdates() =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, AiModel?>> getSelectedModel() =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, void>> selectModel(String modelId) =>
      throw UnimplementedError();
}
