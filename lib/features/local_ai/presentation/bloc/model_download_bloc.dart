import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/local_ai/domain/usecases/local_ai_usecases.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_event.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_state.dart';

/// BLoC that orchestrates model listing, downloading, and selection.
///
/// Per-download errors are surfaced via [ModelsLoaded.downloadErrorMessage] so
/// the model list is never blanked.  [ModelDownloadError] is reserved for hard
/// initial-load failures that require a full retry UI.
class ModelDownloadBloc
    extends Bloc<ModelDownloadEvent, ModelDownloadState> {
  ModelDownloadBloc({
    required this.getAvailableModels,
    required this.downloadModel,
    required this.importLocalModel,
    required this.downloadModelFromUrl,
    required this.checkForUpdates,
    required this.selectModel,
    required this.getSelectedModel,
    required this.repository,
  }) : super(const ModelDownloadInitial()) {
    on<LoadAvailableModels>(_onLoadAvailableModels);
    on<StartModelDownload>(_onStartModelDownload);
    on<StartLocalModelImport>(_onStartLocalModelImport);
    on<StartCustomUrlDownload>(_onStartCustomUrlDownload);
    on<CancelModelDownload>(_onCancelModelDownload);
    on<SelectActiveModel>(_onSelectActiveModel);
    on<CheckModelUpdates>(_onCheckModelUpdates);
    on<ModelDownloadProgressUpdated>(_onProgressUpdated);
  }

  final GetAvailableModels getAvailableModels;
  final DownloadModel downloadModel;
  final ImportLocalModel importLocalModel;
  final DownloadModelFromUrl downloadModelFromUrl;
  final CheckForUpdates checkForUpdates;
  final SelectModel selectModel;
  final GetSelectedModel getSelectedModel;
  final LocalAiRepository repository;

  // ── Handlers ────────────────────────────────────────────────────────────────

  Future<void> _onLoadAvailableModels(
      LoadAvailableModels event, Emitter<ModelDownloadState> emit) async {
    emit(const ModelDownloadLoading());
    final modelsResult = await getAvailableModels(const NoParams());
    final selectedResult = await getSelectedModel(const NoParams());

    modelsResult.fold(
      (failure) => emit(ModelDownloadError(message: failure.message)),
      (models) {
        final selectedId = selectedResult.fold((_) => null, (m) => m?.id);
        emit(ModelsLoaded(models: models, selectedModelId: selectedId));
        // Automatically check for updates in the background after loading.
        add(const CheckModelUpdates());
      },
    );
  }

  Future<void> _onStartModelDownload(
      StartModelDownload event, Emitter<ModelDownloadState> emit) async {
    final current = state;
    if (current is! ModelsLoaded) return;
    if (current.downloadProgress.containsKey(event.model.id)) return;

    // Emit initial progress so the UI shows the progress bar immediately.
    emit(current.copyWith(
      downloadProgress: {...current.downloadProgress, event.model.id: 0.0},
      clearDownloadError: true,
    ));

    final result = await downloadModel(
      DownloadModelParams(
        model: event.model,
        onProgress: (p) => add(
          ModelDownloadProgressUpdated(modelId: event.model.id, progress: p),
        ),
      ),
    );

    await result.fold(
      (failure) async {
        // Use downloadErrorMessage so the model list stays visible.
        final newProgress = Map<String, double>.from(
            (state as ModelsLoaded?)?.downloadProgress ?? {})
          ..remove(event.model.id);
        if (state is ModelsLoaded) {
          emit((state as ModelsLoaded).copyWith(
            downloadProgress: newProgress,
            downloadErrorMessage: failure.message,
          ));
        }
      },
      (_) async {
        // Refresh the full model list so isDownloaded is correct for all models.
        final refreshResult = await getAvailableModels(const NoParams());
        final selectedResult = await getSelectedModel(const NoParams());

        refreshResult.fold(
          (f) => emit(ModelDownloadError(message: f.message)),
          (models) {
            final selectedId =
                selectedResult.fold((_) => null, (m) => m?.id);
            final newProgress = Map<String, double>.from(
                (state as ModelsLoaded?)?.downloadProgress ?? {})
              ..remove(event.model.id);
            emit(ModelsLoaded(
              models: models,
              selectedModelId: selectedId,
              downloadProgress: newProgress,
            ));
          },
        );
      },
    );
  }

  Future<void> _onStartCustomUrlDownload(
      StartCustomUrlDownload event, Emitter<ModelDownloadState> emit) async {
    final current = state;
    if (current is! ModelsLoaded) return;

    // Derive a stable id and file name from the URL.
    final uri = Uri.tryParse(event.url);
    // Use timestamp as suffix for the fallback name to avoid collisions when
    // multiple custom models with invalid/empty URL paths are added.
    final fallbackName =
        'custom_model_${DateTime.now().millisecondsSinceEpoch}.gguf';
    final fileName = (uri?.pathSegments.lastOrNull?.isNotEmpty == true)
        ? uri!.pathSegments.last
        : fallbackName;
    final modelId = 'custom_${fileName.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_')}';
    if (current.downloadProgress.containsKey(modelId)) return;

    emit(current.copyWith(
      downloadProgress: {...current.downloadProgress, modelId: 0.0},
      clearDownloadError: true,
    ));

    final result = await downloadModelFromUrl(
      DownloadModelFromUrlParams(
        url: event.url,
        modelId: modelId,
        displayName: event.displayName,
        fileName: fileName,
        onProgress: (p) => add(
          ModelDownloadProgressUpdated(modelId: modelId, progress: p),
        ),
      ),
    );

    await result.fold(
      (failure) async {
        final newProgress = Map<String, double>.from(
            (state as ModelsLoaded?)?.downloadProgress ?? {})
          ..remove(modelId);
        if (state is ModelsLoaded) {
          emit((state as ModelsLoaded).copyWith(
            downloadProgress: newProgress,
            downloadErrorMessage: failure.message,
          ));
        }
      },
      (_) async {
        final refreshResult = await getAvailableModels(const NoParams());
        final selectedResult = await getSelectedModel(const NoParams());

        refreshResult.fold(
          (f) => emit(ModelDownloadError(message: f.message)),
          (models) {
            final selectedId =
                selectedResult.fold((_) => null, (m) => m?.id);
            final newProgress = Map<String, double>.from(
                (state as ModelsLoaded?)?.downloadProgress ?? {})
              ..remove(modelId);
            emit(ModelsLoaded(
              models: models,
              selectedModelId: selectedId,
              downloadProgress: newProgress,
            ));
          },
        );
      },
    );
  }

  Future<void> _onStartLocalModelImport(
      StartLocalModelImport event, Emitter<ModelDownloadState> emit) async {
    final current = state;
    if (current is! ModelsLoaded) return;

    emit(current.copyWith(clearDownloadError: true));

    final result = await importLocalModel(
      ImportLocalModelParams(existingModelId: event.existingModelId),
    );

    await result.fold(
      (failure) async {
        if (state is ModelsLoaded) {
          emit((state as ModelsLoaded).copyWith(
            downloadErrorMessage: failure.message,
          ));
        }
      },
      (model) async {
        if (model == null) return;
        final refreshResult = await getAvailableModels(const NoParams());
        final selectedResult = await getSelectedModel(const NoParams());

        refreshResult.fold(
          (f) => emit(ModelDownloadError(message: f.message)),
          (models) {
            final selectedId =
                selectedResult.fold((_) => null, (m) => m?.id);
            emit(ModelsLoaded(
              models: models,
              selectedModelId: selectedId,
              downloadProgress: current.downloadProgress,
            ));
          },
        );
      },
    );
  }

  Future<void> _onCancelModelDownload(
      CancelModelDownload event, Emitter<ModelDownloadState> emit) async {
    await repository.cancelDownload(event.modelId);
    if (state is ModelsLoaded) {
      final current = state as ModelsLoaded;
      final newProgress = Map<String, double>.from(current.downloadProgress)
        ..remove(event.modelId);
      emit(current.copyWith(downloadProgress: newProgress));
    }
  }

  Future<void> _onSelectActiveModel(
      SelectActiveModel event, Emitter<ModelDownloadState> emit) async {
    final result = await selectModel(SelectModelParams(modelId: event.modelId));
    result.fold(
      (failure) {
        if (state is ModelsLoaded) {
          emit((state as ModelsLoaded)
              .copyWith(downloadErrorMessage: failure.message));
        }
      },
      (_) {
        if (state is ModelsLoaded) {
          emit(
              (state as ModelsLoaded).copyWith(selectedModelId: event.modelId));
        }
      },
    );
  }

  Future<void> _onCheckModelUpdates(
      CheckModelUpdates event, Emitter<ModelDownloadState> emit) async {
    // Only run when a model list is already loaded.
    if (state is! ModelsLoaded) return;
    final current = state as ModelsLoaded;

    final result = await checkForUpdates(const NoParams());
    result.fold(
      (_) {},
      (updates) {
        if (updates.isNotEmpty) {
          // Keep the current model list visible; add update metadata alongside it.
          emit(current.copyWith(updatableModels: updates));
        }
      },
    );
  }

  void _onProgressUpdated(
      ModelDownloadProgressUpdated event, Emitter<ModelDownloadState> emit) {
    if (state is ModelsLoaded) {
      final current = state as ModelsLoaded;
      emit(current.copyWith(
        downloadProgress: {
          ...current.downloadProgress,
          event.modelId: event.progress,
        },
      ));
    }
  }
}
