import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';

/// Base class for all ProjectMemory BLoC events.
abstract class ProjectMemoryEvent extends Equatable {
  const ProjectMemoryEvent();

  @override
  List<Object?> get props => [];
}

/// Requests loading of all project-memory entries.
class LoadProjectMemories extends ProjectMemoryEvent {
  const LoadProjectMemories();
}

/// Requests the most recent project-memory entry.
class LoadLatestProjectMemory extends ProjectMemoryEvent {
  const LoadLatestProjectMemory();
}

/// Saves a new project-memory entry.
class SaveProjectMemoryEvent extends ProjectMemoryEvent {
  const SaveProjectMemoryEvent({required this.projectMemory});

  final ProjectMemory projectMemory;

  @override
  List<Object?> get props => [projectMemory];
}

/// Updates an existing project-memory entry.
class UpdateProjectMemoryEvent extends ProjectMemoryEvent {
  const UpdateProjectMemoryEvent({required this.projectMemory});

  final ProjectMemory projectMemory;

  @override
  List<Object?> get props => [projectMemory];
}

/// Deletes the project-memory entry with the given [id].
class DeleteProjectMemoryEvent extends ProjectMemoryEvent {
  const DeleteProjectMemoryEvent({required this.id});

  final String id;

  @override
  List<Object?> get props => [id];
}

/// Deletes all project-memory entries (hard reset).
class DeleteAllProjectMemoriesEvent extends ProjectMemoryEvent {
  const DeleteAllProjectMemoriesEvent();
}
