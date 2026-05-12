import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';

abstract class ModelDownloadEvent extends Equatable {
  const ModelDownloadEvent();

  @override
  List<Object?> get props => [];
}

class LoadAvailableModels extends ModelDownloadEvent {
  const LoadAvailableModels();
}

class StartModelDownload extends ModelDownloadEvent {
  const StartModelDownload({required this.model});

  final AiModel model;

  @override
  List<Object?> get props => [model];
}

class CancelModelDownload extends ModelDownloadEvent {
  const CancelModelDownload({required this.modelId});

  final String modelId;

  @override
  List<Object?> get props => [modelId];
}

class SelectActiveModel extends ModelDownloadEvent {
  const SelectActiveModel({required this.modelId});

  final String modelId;

  @override
  List<Object?> get props => [modelId];
}

class CheckModelUpdates extends ModelDownloadEvent {
  const CheckModelUpdates();
}

class ModelDownloadProgressUpdated extends ModelDownloadEvent {
  const ModelDownloadProgressUpdated({
    required this.modelId,
    required this.progress,
  });

  final String modelId;
  final double progress;

  @override
  List<Object?> get props => [modelId, progress];
}

class StartLocalModelImport extends ModelDownloadEvent {
  const StartLocalModelImport({this.existingModelId});

  final String? existingModelId;

  @override
  List<Object?> get props => [existingModelId];
}

/// Triggers a download from a custom URL provided by the user.
class StartCustomUrlDownload extends ModelDownloadEvent {
  const StartCustomUrlDownload({
    required this.url,
    required this.displayName,
  });

  /// The full URL to the GGUF model file (Hugging Face, Ollama, GitHub…).
  final String url;

  /// Human-readable name the user has given to this model.
  final String displayName;

  @override
  List<Object?> get props => [url, displayName];
}
