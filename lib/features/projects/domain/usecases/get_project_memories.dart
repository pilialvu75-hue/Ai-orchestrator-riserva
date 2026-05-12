import 'package:dartz/dartz.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/repositories/project_memory_repository.dart';

/// Retrieves all project-memory entries, ordered newest-first.
class GetProjectMemories implements UseCase<List<ProjectMemory>, NoParams> {
  const GetProjectMemories(this.repository);

  final ProjectMemoryRepository repository;

  @override
  Future<Either<Failure, List<ProjectMemory>>> call(NoParams params) =>
      repository.getAllProjectMemories();
}
