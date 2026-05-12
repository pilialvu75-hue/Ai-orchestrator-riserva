import 'package:dartz/dartz.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/projects/domain/repositories/project_memory_repository.dart';

/// Permanently deletes all project-memory entries (hard reset).
class DeleteAllProjectMemories implements UseCase<bool, NoParams> {
  const DeleteAllProjectMemories(this.repository);

  final ProjectMemoryRepository repository;

  @override
  Future<Either<Failure, bool>> call(NoParams params) =>
      repository.deleteAllProjectMemories();
}
