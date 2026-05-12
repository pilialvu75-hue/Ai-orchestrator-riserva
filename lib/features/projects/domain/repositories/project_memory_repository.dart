import 'package:dartz/dartz.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';

/// Abstract repository that the domain layer depends on.
///
/// The data layer provides the concrete implementation so that the domain
/// stays completely decoupled from persistence details.
abstract class ProjectMemoryRepository {
  /// Returns all stored project-memory entries, newest first.
  Future<Either<Failure, List<ProjectMemory>>> getAllProjectMemories();

  /// Returns the most recently updated entry, or [NotFoundFailure] if none.
  Future<Either<Failure, ProjectMemory>> getLatestProjectMemory();

  /// Returns the entry with the given [id], or [NotFoundFailure] if missing.
  Future<Either<Failure, ProjectMemory>> getProjectMemoryById(String id);

  /// Persists a new [projectMemory] entry and returns it.
  Future<Either<Failure, ProjectMemory>> saveProjectMemory(
      ProjectMemory projectMemory);

  /// Updates an existing entry and returns the updated entity.
  Future<Either<Failure, ProjectMemory>> updateProjectMemory(
      ProjectMemory projectMemory);

  /// Permanently deletes the entry with the given [id].
  Future<Either<Failure, bool>> deleteProjectMemory(String id);

  /// Deletes all entries (hard reset).
  Future<Either<Failure, bool>> deleteAllProjectMemories();
}
