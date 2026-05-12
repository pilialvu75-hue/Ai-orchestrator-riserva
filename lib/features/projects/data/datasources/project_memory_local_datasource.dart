import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/projects/data/models/project_memory_model.dart';

/// Contract for the local SQLite data source.
abstract class ProjectMemoryLocalDataSource {
  Future<List<ProjectMemoryModel>> getAllProjectMemories();
  Future<ProjectMemoryModel> getLatestProjectMemory();
  Future<ProjectMemoryModel> getProjectMemoryById(String id);
  Future<ProjectMemoryModel> saveProjectMemory(ProjectMemoryModel model);
  Future<ProjectMemoryModel> updateProjectMemory(ProjectMemoryModel model);
  Future<bool> deleteProjectMemory(String id);
  Future<bool> deleteAllProjectMemories();
}

/// SQLite-backed implementation of [ProjectMemoryLocalDataSource].
class ProjectMemoryLocalDataSourceImpl implements ProjectMemoryLocalDataSource {
  const ProjectMemoryLocalDataSourceImpl({required this.databaseHelper});

  final DatabaseHelper databaseHelper;

  @override
  Future<List<ProjectMemoryModel>> getAllProjectMemories() async {
    try {
      final rows = await databaseHelper.getAllProjectMemories();
      return rows.map(ProjectMemoryModel.fromMap).toList();
    } catch (e) {
      throw DatabaseException(e.toString());
    }
  }

  @override
  Future<ProjectMemoryModel> getLatestProjectMemory() async {
    try {
      final row = await databaseHelper.getLatestProjectMemory();
      if (row == null) throw const NotFoundException('No project memory found');
      return ProjectMemoryModel.fromMap(row);
    } on NotFoundException {
      rethrow;
    } catch (e) {
      throw DatabaseException(e.toString());
    }
  }

  @override
  Future<ProjectMemoryModel> getProjectMemoryById(String id) async {
    try {
      final row = await databaseHelper.getProjectMemoryById(id);
      if (row == null) {
        throw NotFoundException('ProjectMemory with id $id not found');
      }
      return ProjectMemoryModel.fromMap(row);
    } on NotFoundException {
      rethrow;
    } catch (e) {
      throw DatabaseException(e.toString());
    }
  }

  @override
  Future<ProjectMemoryModel> saveProjectMemory(
      ProjectMemoryModel model) async {
    try {
      await databaseHelper.insertProjectMemory(model.toMap());
      return model;
    } catch (e) {
      throw DatabaseException(e.toString());
    }
  }

  @override
  Future<ProjectMemoryModel> updateProjectMemory(
      ProjectMemoryModel model) async {
    try {
      final count = await databaseHelper.updateProjectMemory(model.toMap());
      if (count == 0) {
        throw NotFoundException(
            'ProjectMemory with id ${model.id} not found for update');
      }
      return model;
    } on NotFoundException {
      rethrow;
    } catch (e) {
      throw DatabaseException(e.toString());
    }
  }

  @override
  Future<bool> deleteProjectMemory(String id) async {
    try {
      final count = await databaseHelper.deleteProjectMemory(id);
      return count > 0;
    } catch (e) {
      throw DatabaseException(e.toString());
    }
  }

  @override
  Future<bool> deleteAllProjectMemories() async {
    try {
      await databaseHelper.deleteAllProjectMemories();
      return true;
    } catch (e) {
      throw DatabaseException(e.toString());
    }
  }
}
