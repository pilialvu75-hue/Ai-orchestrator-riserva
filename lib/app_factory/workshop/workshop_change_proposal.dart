import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';

/// Describes the result proposed by the Workshop coding model.
///
/// A proposal is NOT an applied change.
///
/// The LLM can explain what it wants to do and provide the proposed
/// file contents, but the repository is not modified by this class.
///
/// Intended flow:
///
///   LLM response
///        ↓
///   WorkshopChangeProposal
///        ↓
///   VirtualWorkspace
///        ↓
///   WorkspaceDiff
///        ↓
///   validation
///        ↓
///   explicit approval
///        ↓
///   real workspace
final class WorkshopChangeProposal {
  const WorkshopChangeProposal({
    required this.requestId,
    required this.explanation,
    required this.changes,
    this.summary,
    this.analysis,
    this.validationNotes = const <String>[],
    this.warnings = const <String>[],
  });

  /// Workshop request that produced this proposal.
  final String requestId;

  /// Short human-readable summary of the proposed work.
  final String? summary;

  /// Natural-language explanation of the reasoning and intended changes.
  final String explanation;

  /// Optional deeper technical analysis.
  final String? analysis;

  /// Proposed file changes.
  final List<WorkspaceFileChange> changes;

  /// Notes that should be considered before validation/application.
  final List<String> validationNotes;

  /// Non-blocking warnings.
  final List<String> warnings;

  bool get isEmpty => changes.isEmpty;

  bool get isNotEmpty => changes.isNotEmpty;

  int get changeCount => changes.length;

  int get additions =>
      changes.where((change) => change.isAddition).length;

  int get modifications =>
      changes.where((change) => change.isModification).length;

  int get deletions =>
      changes.where((change) => change.isDeletion).length;

  /// Creates the deterministic workspace diff represented by this proposal.
  WorkspaceDiff buildDiff() {
    return WorkspaceDiff(
      changes: List<WorkspaceFileChange>.unmodifiable(changes),
    );
  }

  /// Returns the paths affected by this proposal.
  List<String> get affectedPaths {
    final paths = changes
        .map((change) => change.path)
        .toSet()
        .toList()
      ..sort();

    return List.unmodifiable(paths);
  }

  /// Returns only the changes affecting [path].
  List<WorkspaceFileChange> changesForPath(
    String path,
  ) {
    return List.unmodifiable(
      changes.where((change) => change.path == path),
    );
  }

  /// Creates a copy with selected fields replaced.
  WorkshopChangeProposal copyWith({
    String? requestId,
    String? summary,
    String? explanation,
    String? analysis,
    List<WorkspaceFileChange>? changes,
    List<String>? validationNotes,
    List<String>? warnings,
  }) {
    return WorkshopChangeProposal(
      requestId: requestId ?? this.requestId,
      summary: summary ?? this.summary,
      explanation: explanation ?? this.explanation,
      analysis: analysis ?? this.analysis,
      changes: changes ?? this.changes,
      validationNotes:
          validationNotes ?? this.validationNotes,
      warnings: warnings ?? this.warnings,
    );
  }

  @override
  String toString() {
    return 'WorkshopChangeProposal('
        'requestId: $requestId, '
        'changes: $changeCount, '
        'additions: $additions, '
        'modifications: $modifications, '
        'deletions: $deletions'
        ')';
  }
}
