import 'package:dartz/dartz.dart';
import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';

/// Returns all available models with their current download status.
class GetAvailableModels extends UseCase<List<AiModel>, NoParams> {
  GetAvailableModels(this.repository);

  final LocalAiRepository repository;

  @override
  Future<Either<Failure, List<AiModel>>> call(NoParams params) =>
      repository.getAvailableModels();
}

// ── DownloadModel ─────────────────────────────────────────────────────────────

class DownloadModelParams extends Equatable {
  const DownloadModelParams({
    required this.model,
    this.onProgress,
  });

  final AiModel model;
  final void Function(double progress)? onProgress;

  @override
  List<Object?> get props => [model];
}

/// Downloads an AI model file to device storage.
class DownloadModel extends UseCase<AiModel, DownloadModelParams> {
  DownloadModel(this.repository);

  final LocalAiRepository repository;

  @override
  Future<Either<Failure, AiModel>> call(DownloadModelParams params) =>
      repository.downloadModel(
        params.model,
        onProgress: params.onProgress,
      );
}

// ── CheckForUpdates ───────────────────────────────────────────────────────────

/// Queries the remote manifest and returns models that have newer versions.
class CheckForUpdates extends UseCase<List<AiModel>, NoParams> {
  CheckForUpdates(this.repository);

  final LocalAiRepository repository;

  @override
  Future<Either<Failure, List<AiModel>>> call(NoParams params) =>
      repository.checkForUpdates();
}

// ── SelectModel ───────────────────────────────────────────────────────────────

class SelectModelParams extends Equatable {
  const SelectModelParams({required this.modelId});

  final String modelId;

  @override
  List<Object?> get props => [modelId];
}

/// Persists the user's active model selection.
class SelectModel extends UseCase<void, SelectModelParams> {
  SelectModel(this.repository);

  final LocalAiRepository repository;

  @override
  Future<Either<Failure, void>> call(SelectModelParams params) =>
      repository.selectModel(params.modelId);
}

// ── DownloadModelFromUrl ──────────────────────────────────────────────────────

class DownloadModelFromUrlParams extends Equatable {
  const DownloadModelFromUrlParams({
    required this.url,
    required this.modelId,
    required this.displayName,
    required this.fileName,
    this.onProgress,
  });

  final String url;
  final String modelId;
  final String displayName;
  final String fileName;
  final void Function(double progress)? onProgress;

  @override
  List<Object?> get props => [url, modelId, displayName, fileName];
}

/// Downloads an AI model from a user-supplied URL (Hugging Face, Ollama…).
class DownloadModelFromUrl
    extends UseCase<AiModel, DownloadModelFromUrlParams> {
  DownloadModelFromUrl(this.repository);

  final LocalAiRepository repository;

  @override
  Future<Either<Failure, AiModel>> call(
          DownloadModelFromUrlParams params) =>
      repository.downloadModelFromUrl(
        params.url,
        modelId: params.modelId,
        displayName: params.displayName,
        fileName: params.fileName,
        onProgress: params.onProgress,
      );
}

// ── GetSelectedModel ──────────────────────────────────────────────────────────

/// Returns the currently selected model, or null if none.
class GetSelectedModel extends UseCase<AiModel?, NoParams> {
  GetSelectedModel(this.repository);

  final LocalAiRepository repository;

  @override
  Future<Either<Failure, AiModel?>> call(NoParams params) =>
      repository.getSelectedModel();
}

// ── ImportLocalModel ───────────────────────────────────────────────────────────

class ImportLocalModelParams extends Equatable {
  const ImportLocalModelParams({this.existingModelId});

  final String? existingModelId;

  @override
  List<Object?> get props => [existingModelId];
}

/// Imports or re-links an existing GGUF model already present on device
/// storage.
class ImportLocalModel extends UseCase<AiModel?, ImportLocalModelParams> {
  ImportLocalModel(this.repository);

  final LocalAiRepository repository;

  @override
  Future<Either<Failure, AiModel?>> call(ImportLocalModelParams params) =>
      repository.importLocalModel(existingModelId: params.existingModelId);
}
