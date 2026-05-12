import 'package:dartz/dartz.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/repositories/project_memory_repository.dart';

/// Retrieves the most recently updated project-memory entry.
class GetLatestProjectMemory
    implements UseCase<ProjectMemory, NoParams> {
  const GetLatestProjectMemory(this.repository);

  final ProjectMemoryRepository repository;

  @override
  Future<Either<Failure, ProjectMemory>> call(NoParams params) =>
      repository.getLatestProjectMemory();
}
