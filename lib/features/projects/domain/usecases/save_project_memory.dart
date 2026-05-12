import 'package:dartz/dartz.dart';
import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/repositories/project_memory_repository.dart';

/// Persists a new project-memory entry.
class SaveProjectMemory implements UseCase<ProjectMemory, SaveProjectMemoryParams> {
  const SaveProjectMemory(this.repository);

  final ProjectMemoryRepository repository;

  @override
  Future<Either<Failure, ProjectMemory>> call(
          SaveProjectMemoryParams params) =>
      repository.saveProjectMemory(params.projectMemory);
}

class SaveProjectMemoryParams extends Equatable {
  const SaveProjectMemoryParams({required this.projectMemory});

  final ProjectMemory projectMemory;

  @override
  List<Object?> get props => [projectMemory];
}
