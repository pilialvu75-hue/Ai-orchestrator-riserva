import 'package:dartz/dartz.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';
import 'package:ai_orchestrator/features/local_ai/data/services/model_download_service.dart';

class LocalAiRepositoryImpl implements LocalAiRepository {
  LocalAiRepositoryImpl({required this.downloadService});

  final ModelDownloadService downloadService;

  @override
  Future<Either<Failure, List<AiModel>>> getAvailableModels() async {
    try {
      final models = await downloadService.getAvailableModels();
      return Right(models);
    } catch (e) {
      return Left(DatabaseFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, AiModel>> downloadModel(
    AiModel model, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final result = await downloadService.downloadModel(
        model,
        onProgress: onProgress,
      );
      return Right(result);
    } on DownloadException catch (e) {
      return Left(DownloadFailure(e.message));
    } catch (e) {
      return Left(DownloadFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, AiModel>> downloadModelFromUrl(
    String url, {
    required String modelId,
    required String displayName,
    required String fileName,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final result = await downloadService.downloadModelFromUrl(
        url,
        modelId: modelId,
        displayName: displayName,
        fileName: fileName,
        onProgress: onProgress,
      );
      return Right(result);
    } on DownloadException catch (e) {
      return Left(DownloadFailure(e.message));
    } catch (e) {
      return Left(DownloadFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, AiModel?>> importLocalModel({
    String? existingModelId,
  }) async {
    try {
      final result = await downloadService.importLocalModel(
        existingModelId: existingModelId,
      );
      return Right(result);
    } on DownloadException catch (e) {
      return Left(DownloadFailure(e.message));
    } catch (e) {
      return Left(DownloadFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> cancelDownload(String modelId) async {
    downloadService.cancelDownload(modelId);
    return const Right(null);
  }

  @override
  Future<Either<Failure, void>> deleteModel(String modelId) async {
    try {
      final models = await downloadService.getAvailableModels();
      final model = models.where((m) => m.id == modelId).firstOrNull;
      if (model != null) {
        await downloadService.deleteModel(model);
      }
      return const Right(null);
    } catch (e) {
      return Left(DatabaseFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, List<AiModel>>> checkForUpdates() async {
    try {
      final current = await downloadService.getAvailableModels();
      final updates = await downloadService.checkForUpdates(current);
      return Right(updates);
    } catch (e) {
      return Left(NetworkFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, AiModel?>> getSelectedModel() async {
    try {
      final modelId = await downloadService.loadSelectedModelId();
      if (modelId == null) return const Right(null);
      final models = await downloadService.getAvailableModels();
      final selected = models.where((m) => m.id == modelId).firstOrNull;
      return Right(selected);
    } catch (e) {
      return Left(DatabaseFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> selectModel(String modelId) async {
    try {
      await downloadService.saveSelectedModel(modelId);
      return const Right(null);
    } catch (e) {
      return Left(DatabaseFailure(e.toString()));
    }
  }
}
