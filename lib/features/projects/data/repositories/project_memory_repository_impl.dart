import 'package:dartz/dartz.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/repositories/project_memory_repository.dart';
import 'package:ai_orchestrator/features/projects/data/datasources/project_memory_local_datasource.dart';
import 'package:ai_orchestrator/features/projects/data/models/project_memory_model.dart';

/// Concrete repository implementation backed by SQLite via
/// [ProjectMemoryLocalDataSource].
class ProjectMemoryRepositoryImpl implements ProjectMemoryRepository {
  const ProjectMemoryRepositoryImpl({required this.localDataSource});

  final ProjectMemoryLocalDataSource localDataSource;

  @override
  Future<Either<Failure, List<ProjectMemory>>> getAllProjectMemories() async {
    try {
      final models = await localDataSource.getAllProjectMemories();
      return Right(models);
    } on DatabaseException catch (e) {
      return Left(DatabaseFailure(e.message));
    }
  }

  @override
  Future<Either<Failure, ProjectMemory>> getLatestProjectMemory() async {
    try {
      final model = await localDataSource.getLatestProjectMemory();
      return Right(model);
    } on NotFoundException catch (e) {
      return Left(NotFoundFailure(e.message));
    } on DatabaseException catch (e) {
      return Left(DatabaseFailure(e.message));
    }
  }

  @override
  Future<Either<Failure, ProjectMemory>> getProjectMemoryById(
      String id) async {
    try {
      final model = await localDataSource.getProjectMemoryById(id);
      return Right(model);
    } on NotFoundException catch (e) {
      return Left(NotFoundFailure(e.message));
    } on DatabaseException catch (e) {
      return Left(DatabaseFailure(e.message));
    }
  }

  @override
  Future<Either<Failure, ProjectMemory>> saveProjectMemory(
      ProjectMemory projectMemory) async {
    try {
      final model = await localDataSource
          .saveProjectMemory(ProjectMemoryModel.fromEntity(projectMemory));
      return Right(model);
    } on DatabaseException catch (e) {
      return Left(DatabaseFailure(e.message));
    }
  }

  @override
  Future<Either<Failure, ProjectMemory>> updateProjectMemory(
      ProjectMemory projectMemory) async {
    try {
      final model = await localDataSource
          .updateProjectMemory(ProjectMemoryModel.fromEntity(projectMemory));
      return Right(model);
    } on NotFoundException catch (e) {
      return Left(NotFoundFailure(e.message));
    } on DatabaseException catch (e) {
      return Left(DatabaseFailure(e.message));
    }
  }

  @override
  Future<Either<Failure, bool>> deleteProjectMemory(String id) async {
    try {
      final success = await localDataSource.deleteProjectMemory(id);
      return Right(success);
    } on DatabaseException catch (e) {
      return Left(DatabaseFailure(e.message));
    }
  }

  @override
  Future<Either<Failure, bool>> deleteAllProjectMemories() async {
    try {
      final success = await localDataSource.deleteAllProjectMemories();
      return Right(success);
    } on DatabaseException catch (e) {
      return Left(DatabaseFailure(e.message));
    }
  }
}
