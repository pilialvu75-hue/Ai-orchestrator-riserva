import 'package:dartz/dartz.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';

/// Core contract for local AI model management.
///
/// Local AI feature implementations must satisfy this interface so the
/// unified inference runtime can discover, download, and
/// select on-device models without depending on feature-layer internals.
abstract class LocalAiRepository {
  /// Returns the list of all available models with their current download state.
  Future<Either<Failure, List<AiModel>>> getAvailableModels();

  /// Downloads [model] to device storage, reporting progress via [onProgress].
  ///
  /// [onProgress] receives values between 0.0 and 1.0.
  Future<Either<Failure, AiModel>> downloadModel(
    AiModel model, {
    void Function(double progress)? onProgress,
  });

  /// Downloads a model from a user-supplied [url].
  ///
  /// [modelId]     – a unique identifier for the custom model.
  /// [displayName] – human-readable name shown in the UI.
  /// [fileName]    – file name used when storing the model on disk.
  /// [onProgress]  – optional 0.0–1.0 progress callback.
  Future<Either<Failure, AiModel>> downloadModelFromUrl(
    String url, {
    required String modelId,
    required String displayName,
    required String fileName,
    void Function(double progress)? onProgress,
  });

  /// Imports an existing GGUF model from device storage.
  ///
  /// When [existingModelId] is supplied, the imported file re-links an existing
  /// local import instead of creating a new registry entry.
  Future<Either<Failure, AiModel?>> importLocalModel({
    String? existingModelId,
  });

  /// Cancels an in-progress download for [modelId].
  Future<Either<Failure, void>> cancelDownload(String modelId);

  /// Deletes the local file for [modelId].
  Future<Either<Failure, void>> deleteModel(String modelId);

  /// Checks the remote version manifest and returns models that have updates.
  Future<Either<Failure, List<AiModel>>> checkForUpdates();

  /// Returns the model that the user has selected as their active model, or
  /// `null` if none has been selected.
  Future<Either<Failure, AiModel?>> getSelectedModel();

  /// Persists the user's model selection.
  Future<Either<Failure, void>> selectModel(String modelId);
}
