import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/delete_all_project_memories.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/delete_project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/get_latest_project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/get_project_memories.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/save_project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/update_project_memory.dart';
import 'package:ai_orchestrator/features/projects/presentation/bloc/project_memory_event.dart';
import 'package:ai_orchestrator/features/projects/presentation/bloc/project_memory_state.dart';

/// BLoC that orchestrates all project-memory UI interactions.
class ProjectMemoryBloc
    extends Bloc<ProjectMemoryEvent, ProjectMemoryState> {
  ProjectMemoryBloc({
    required this.getProjectMemories,
    required this.getLatestProjectMemory,
    required this.saveProjectMemory,
    required this.updateProjectMemory,
    required this.deleteProjectMemory,
    required this.deleteAllProjectMemories,
  }) : super(const ProjectMemoryInitial()) {
    on<LoadProjectMemories>(_onLoadProjectMemories);
    on<LoadLatestProjectMemory>(_onLoadLatestProjectMemory);
    on<SaveProjectMemoryEvent>(_onSaveProjectMemory);
    on<UpdateProjectMemoryEvent>(_onUpdateProjectMemory);
    on<DeleteProjectMemoryEvent>(_onDeleteProjectMemory);
    on<DeleteAllProjectMemoriesEvent>(_onDeleteAllProjectMemories);
  }

  final GetProjectMemories getProjectMemories;
  final GetLatestProjectMemory getLatestProjectMemory;
  final SaveProjectMemory saveProjectMemory;
  final UpdateProjectMemory updateProjectMemory;
  final DeleteProjectMemory deleteProjectMemory;
  final DeleteAllProjectMemories deleteAllProjectMemories;

  // ── Event handlers ──────────────────────────────────────────────────────────

  Future<void> _onLoadProjectMemories(
      LoadProjectMemories event, Emitter<ProjectMemoryState> emit) async {
    emit(const ProjectMemoryLoading());
    final result = await getProjectMemories(const NoParams());
    result.fold(
      (failure) => emit(ProjectMemoryError(message: failure.message)),
      (memories) => emit(ProjectMemoriesLoaded(memories: memories)),
    );
  }

  Future<void> _onLoadLatestProjectMemory(
      LoadLatestProjectMemory event, Emitter<ProjectMemoryState> emit) async {
    emit(const ProjectMemoryLoading());
    final result = await getLatestProjectMemory(const NoParams());
    result.fold(
      (failure) => emit(ProjectMemoryError(message: failure.message)),
      (memory) => emit(ProjectMemoryLoaded(memory: memory)),
    );
  }

  Future<void> _onSaveProjectMemory(
      SaveProjectMemoryEvent event, Emitter<ProjectMemoryState> emit) async {
    emit(const ProjectMemoryLoading());
    final result = await saveProjectMemory(
        SaveProjectMemoryParams(projectMemory: event.projectMemory));
    result.fold(
      (failure) => emit(ProjectMemoryError(message: failure.message)),
      (memory) => emit(ProjectMemoryLoaded(memory: memory)),
    );
  }

  Future<void> _onUpdateProjectMemory(
      UpdateProjectMemoryEvent event, Emitter<ProjectMemoryState> emit) async {
    emit(const ProjectMemoryLoading());
    final result = await updateProjectMemory(
        UpdateProjectMemoryParams(projectMemory: event.projectMemory));
    result.fold(
      (failure) => emit(ProjectMemoryError(message: failure.message)),
      (memory) => emit(ProjectMemoryLoaded(memory: memory)),
    );
  }

  Future<void> _onDeleteProjectMemory(
      DeleteProjectMemoryEvent event, Emitter<ProjectMemoryState> emit) async {
    emit(const ProjectMemoryLoading());
    final result =
        await deleteProjectMemory(DeleteProjectMemoryParams(id: event.id));
    result.fold(
      (failure) => emit(ProjectMemoryError(message: failure.message)),
      (_) => emit(
          const ProjectMemoryOperationSuccess(message: 'Memory deleted')),
    );
  }

  Future<void> _onDeleteAllProjectMemories(DeleteAllProjectMemoriesEvent event,
      Emitter<ProjectMemoryState> emit) async {
    emit(const ProjectMemoryLoading());
    final result = await deleteAllProjectMemories(const NoParams());
    result.fold(
      (failure) => emit(ProjectMemoryError(message: failure.message)),
      (_) => emit(
          const ProjectMemoryOperationSuccess(message: 'All memories deleted')),
    );
  }
}
