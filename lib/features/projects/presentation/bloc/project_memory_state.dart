import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';

/// Base class for all ProjectMemory BLoC states.
abstract class ProjectMemoryState extends Equatable {
  const ProjectMemoryState();

  @override
  List<Object?> get props => [];
}

/// Initial / idle state.
class ProjectMemoryInitial extends ProjectMemoryState {
  const ProjectMemoryInitial();
}

/// Loading is in progress.
class ProjectMemoryLoading extends ProjectMemoryState {
  const ProjectMemoryLoading();
}

/// A list of entries has been loaded successfully.
class ProjectMemoriesLoaded extends ProjectMemoryState {
  const ProjectMemoriesLoaded({required this.memories});

  final List<ProjectMemory> memories;

  @override
  List<Object?> get props => [memories];
}

/// A single entry has been loaded or acted upon successfully.
class ProjectMemoryLoaded extends ProjectMemoryState {
  const ProjectMemoryLoaded({required this.memory});

  final ProjectMemory memory;

  @override
  List<Object?> get props => [memory];
}

/// An operation completed successfully with no entity to return.
class ProjectMemoryOperationSuccess extends ProjectMemoryState {
  const ProjectMemoryOperationSuccess({required this.message});

  final String message;

  @override
  List<Object?> get props => [message];
}

/// An error occurred during a BLoC operation.
class ProjectMemoryError extends ProjectMemoryState {
  const ProjectMemoryError({required this.message});

  final String message;

  @override
  List<Object?> get props => [message];
}
