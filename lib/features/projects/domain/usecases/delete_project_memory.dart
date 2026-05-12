import 'package:dartz/dartz.dart';
import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/projects/domain/repositories/project_memory_repository.dart';

/// Permanently deletes a project-memory entry by its [id].
class DeleteProjectMemory implements UseCase<bool, DeleteProjectMemoryParams> {
  const DeleteProjectMemory(this.repository);

  final ProjectMemoryRepository repository;

  @override
  Future<Either<Failure, bool>> call(DeleteProjectMemoryParams params) =>
      repository.deleteProjectMemory(params.id);
}

class DeleteProjectMemoryParams extends Equatable {
  const DeleteProjectMemoryParams({required this.id});

  final String id;

  @override
  List<Object?> get props => [id];
}
