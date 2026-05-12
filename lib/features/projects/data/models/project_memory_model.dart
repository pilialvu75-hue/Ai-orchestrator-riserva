import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';

/// Data-layer model that maps [ProjectMemory] to/from SQLite rows.
class ProjectMemoryModel extends ProjectMemory {
  const ProjectMemoryModel({
    required super.id,
    required super.masterGoal,
    required super.currentContext,
    required super.lastCodeSnippet,
    required super.timestamp,
  });

  // ── Factories ───────────────────────────────────────────────────────────────

  factory ProjectMemoryModel.fromMap(Map<String, dynamic> map) {
    return ProjectMemoryModel(
      // Usiamo 'toString()' o il cast sicuro per evitare crash se il dato è nullo o diverso
      id: map[AppConstants.colId]?.toString() ?? '',
      masterGoal: map[AppConstants.colMasterGoal]?.toString() ?? '',
      currentContext: map[AppConstants.colCurrentContext]?.toString() ?? '',
      lastCodeSnippet: map[AppConstants.colLastCodeSnippet]?.toString() ?? '',
      // Per il timestamp, ci assicuriamo che sia un intero
      timestamp: (map[AppConstants.colTimestamp] as int?) ?? 0,
    );
  }

  factory ProjectMemoryModel.fromEntity(ProjectMemory entity) {
    return ProjectMemoryModel(
      id: entity.id,
      masterGoal: entity.masterGoal,
      currentContext: entity.currentContext,
      lastCodeSnippet: entity.lastCodeSnippet,
      timestamp: entity.timestamp,
    );
  }

  // ── Serialisation ───────────────────────────────────────────────────────────

  Map<String, dynamic> toMap() {
    return {
      AppConstants.colId: id,
      AppConstants.colMasterGoal: masterGoal,
      AppConstants.colCurrentContext: currentContext,
      AppConstants.colLastCodeSnippet: lastCodeSnippet,
      AppConstants.colTimestamp: timestamp,
    };
  }

  @override
  ProjectMemoryModel copyWith({
    String? id,
    String? masterGoal,
    String? currentContext,
    String? lastCodeSnippet,
    int? timestamp,
  }) {
    return ProjectMemoryModel(
      id: id ?? this.id,
      masterGoal: masterGoal ?? this.masterGoal,
      currentContext: currentContext ?? this.currentContext,
      lastCodeSnippet: lastCodeSnippet ?? this.lastCodeSnippet,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}
