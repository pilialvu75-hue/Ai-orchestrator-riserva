import 'dart:async';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';
import 'package:ai_orchestrator/features/local_ai/domain/usecases/local_ai_usecases.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_event.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_state.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Repository extends Mock implements LocalAiRepository {}

void main() {
  const phi = AiModel(
      id: 'phi3_5_mini',
      displayName: 'Phi',
      fileName: 'phi.gguf',
      downloadUrl: '',
      version: '1',
      sizeBytes: 1,
      description: 'fixture');
  final nemotron = phi.copyWith(id: 'nemotron3_nano_4b');

  test('late update check cannot restore the previous selected model',
      () async {
    final repo = _Repository();
    final updates = Completer<Either<Failure, List<AiModel>>>();
    final checking = Completer<void>();
    when(() => repo.getAvailableModels())
        .thenAnswer((_) async => Right([phi, nemotron]));
    when(() => repo.getSelectedModel())
        .thenAnswer((_) async => const Right(phi));
    when(() => repo.selectModel(nemotron.id))
        .thenAnswer((_) async => const Right(null));
    when(() => repo.checkForUpdates()).thenAnswer((_) {
      checking.complete();
      return updates.future;
    });
    final bloc = ModelDownloadBloc(
      getAvailableModels: GetAvailableModels(repo),
      downloadModel: DownloadModel(repo),
      importLocalModel: ImportLocalModel(repo),
      downloadModelFromUrl: DownloadModelFromUrl(repo),
      checkForUpdates: CheckForUpdates(repo),
      selectModel: SelectModel(repo),
      getSelectedModel: GetSelectedModel(repo),
      repository: repo,
    );
    addTearDown(bloc.close);
    bloc.add(const LoadAvailableModels());
    await checking.future;
    final selected = bloc.stream.firstWhere(
        (s) => s is ModelsLoaded && s.selectedModelId == nemotron.id);
    bloc.add(SelectActiveModel(modelId: nemotron.id));
    await selected;
    final refreshed = bloc.stream
        .firstWhere((s) => s is ModelsLoaded && s.updatableModels.isNotEmpty);
    updates.complete(Right([phi]));
    final state = await refreshed as ModelsLoaded;
    expect(state.selectedModelId, nemotron.id);
    verify(() => repo.selectModel(nemotron.id)).called(1);
  });
}
