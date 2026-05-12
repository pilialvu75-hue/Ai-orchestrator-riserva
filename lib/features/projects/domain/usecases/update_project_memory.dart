import 'package:dartz/dartz.dart';
import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/repositories/project_memory_repository.dart';

/// Updates an existing project-memory entry.
class UpdateProjectMemory
    implements UseCase<ProjectMemory, UpdateProjectMemoryParams> {
  const UpdateProjectMemory(this.repository);

  final ProjectMemoryRepository repository;

  @override
  Future<Either<Failure, ProjectMemory>> call(
          UpdateProjectMemoryParams params) =>
      repository.updateProjectMemory(params.projectMemory);
}

class UpdateProjectMemoryParams extends Equatable {
  const UpdateProjectMemoryParams({required this.projectMemory});

  final ProjectMemory projectMemory;

  @override
  List<Object?> get props => [projectMemory];
}
