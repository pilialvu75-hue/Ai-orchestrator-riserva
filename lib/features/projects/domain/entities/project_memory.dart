import 'package:equatable/equatable.dart';

/// Domain entity representing a snapshot of the AI-Orchestrator project state.
///
/// This is a pure Dart class with no framework dependencies — it belongs
/// exclusively to the **domain layer**.
class ProjectMemory extends Equatable {
  const ProjectMemory({
    required this.id,
    required this.masterGoal,
    required this.currentContext,
    required this.lastCodeSnippet,
    required this.timestamp,
  });

  /// Unique identifier (UUID v4).
  final String id;

  /// The overarching goal of the project (e.g. "Build a Flutter offline AI app").
  final String masterGoal;

  /// Free-form context that describes the current state of work.
  final String currentContext;

  /// The most relevant code snippet from the last working session.
  final String lastCodeSnippet;

  /// When this snapshot was created/updated (UTC epoch milliseconds).
  final int timestamp;

  /// Returns a copy with the supplied fields overridden.
  ProjectMemory copyWith({
    String? id,
    String? masterGoal,
    String? currentContext,
    String? lastCodeSnippet,
    int? timestamp,
  }) {
    return ProjectMemory(
      id: id ?? this.id,
      masterGoal: masterGoal ?? this.masterGoal,
      currentContext: currentContext ?? this.currentContext,
      lastCodeSnippet: lastCodeSnippet ?? this.lastCodeSnippet,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  @override
  List<Object?> get props =>
      [id, masterGoal, currentContext, lastCodeSnippet, timestamp];

  @override
  String toString() =>
      'ProjectMemory(id: $id, masterGoal: $masterGoal, timestamp: $timestamp)';
}
