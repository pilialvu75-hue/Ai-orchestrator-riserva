import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';

abstract class ModelDownloadState extends Equatable {
  const ModelDownloadState();

  @override
  List<Object?> get props => [];
}

class ModelDownloadInitial extends ModelDownloadState {
  const ModelDownloadInitial();
}

class ModelDownloadLoading extends ModelDownloadState {
  const ModelDownloadLoading();
}

class ModelsLoaded extends ModelDownloadState {
  const ModelsLoaded({
    required this.models,
    this.selectedModelId,
    this.downloadProgress = const {},
    this.downloadErrorMessage,
    this.updatableModels = const [],
  });

  final List<AiModel> models;
  final String? selectedModelId;

  /// Maps modelId → download progress (0.0–1.0).
  final Map<String, double> downloadProgress;

  /// Non-null when a per-model download failed.  Surfaced as a SnackBar so the
  /// model list is not blanked.  Use [ModelDownloadError] only for hard
  /// initial-load failures that require a full retry UI.
  final String? downloadErrorMessage;

  /// Models for which a newer remote version has been detected.
  final List<AiModel> updatableModels;

  ModelsLoaded copyWith({
    List<AiModel>? models,
    String? selectedModelId,
    Map<String, double>? downloadProgress,
    bool clearSelectedModel = false,
    String? downloadErrorMessage,
    bool clearDownloadError = false,
    List<AiModel>? updatableModels,
  }) {
    return ModelsLoaded(
      models: models ?? this.models,
      selectedModelId:
          clearSelectedModel ? null : (selectedModelId ?? this.selectedModelId),
      downloadProgress: downloadProgress ?? this.downloadProgress,
      downloadErrorMessage: clearDownloadError
          ? null
          : (downloadErrorMessage ?? this.downloadErrorMessage),
      updatableModels: updatableModels ?? this.updatableModels,
    );
  }

  @override
  List<Object?> get props => [
        models,
        selectedModelId,
        downloadProgress,
        downloadErrorMessage,
        updatableModels,
      ];
}

class ModelDownloadError extends ModelDownloadState {
  const ModelDownloadError({required this.message});

  final String message;

  @override
  List<Object?> get props => [message];
}

class ModelUpdateAvailable extends ModelDownloadState {
  const ModelUpdateAvailable({required this.updatableModels});

  final List<AiModel> updatableModels;

  @override
  List<Object?> get props => [updatableModels];
}
