/// Describes the kind of change represented by a workspace diff.
enum WorkspaceChangeType {
  addition,
  modification,
  deletion,
}

/// A single file change inside a [WorkspaceDiff].
///
/// This class deliberately contains only workspace-level information.
/// It does not write to disk and does not interact with GitHub.
class WorkspaceFileChange {
  const WorkspaceFileChange({
    required this.path,
    required this.type,
    this.beforeContent,
    this.afterContent,
  });

  /// Relative path of the file inside the workspace.
  final String path;

  /// Type of change represented by this entry.
  final WorkspaceChangeType type;

  /// Previous file content.
  ///
  /// Null for newly created files.
  final String? beforeContent;

  /// New file content.
  ///
  /// Null for deleted files.
  final String? afterContent;

  bool get isAddition => type == WorkspaceChangeType.addition;

  bool get isModification => type == WorkspaceChangeType.modification;

  bool get isDeletion => type == WorkspaceChangeType.deletion;

  @override
  String toString() {
    return 'WorkspaceFileChange('
        'path: $path, '
        'type: $type'
        ')';
  }
}

/// Represents a complete, deterministic set of changes to a workspace.
///
/// IMPORTANT:
/// This class is intentionally side-effect free.
///
/// It does NOT:
/// - write files;
/// - delete files;
/// - execute Git commands;
/// - access GitHub;
/// - modify the repository.
///
/// Those responsibilities will belong to later layers of the
/// App Factory / Cantiere architecture.
///
/// Keeping the diff pure is important for stability and allows the
/// application to preview, validate, approve, and eventually apply
/// changes independently.
class WorkspaceDiff {
  const WorkspaceDiff({
    required List<WorkspaceFileChange> changes,
  }) : _changes = changes;

  final List<WorkspaceFileChange> _changes;

  /// Immutable view of the changes.
  List<WorkspaceFileChange> get changes =>
      List.unmodifiable(_changes);

  bool get isEmpty => _changes.isEmpty;

  bool get isNotEmpty => _changes.isNotEmpty;

  int get length => _changes.length;

  int get additions =>
      _changes.where((change) => change.isAddition).length;

  int get modifications =>
      _changes.where((change) => change.isModification).length;

  int get deletions =>
      _changes.where((change) => change.isDeletion).length;

  /// Creates a diff between two workspace snapshots.
  ///
  /// The maps must contain workspace-relative file paths as keys and
  /// complete file contents as values.
  ///
  /// A missing path in [before] and present path in [after] is an addition.
  /// A present path in [before] and missing path in [after] is a deletion.
  /// A path present in both with different contents is a modification.
  static WorkspaceDiff compare({
    required Map<String, String> before,
    required Map<String, String> after,
  }) {
    final changes = <WorkspaceFileChange>[];

    final paths = <String>{
      ...before.keys,
      ...after.keys,
    };

    final sortedPaths = paths.toList()..sort();

    for (final path in sortedPaths) {
      final oldContent = before[path];
      final newContent = after[path];

      if (!before.containsKey(path)) {
        changes.add(
          WorkspaceFileChange(
            path: path,
            type: WorkspaceChangeType.addition,
            afterContent: newContent,
          ),
        );
        continue;
      }

      if (!after.containsKey(path)) {
        changes.add(
          WorkspaceFileChange(
            path: path,
            type: WorkspaceChangeType.deletion,
            beforeContent: oldContent,
          ),
        );
        continue;
      }

      if (oldContent != newContent) {
        changes.add(
          WorkspaceFileChange(
            path: path,
            type: WorkspaceChangeType.modification,
            beforeContent: oldContent,
            afterContent: newContent,
          ),
        );
      }
    }

    return WorkspaceDiff(changes: changes);
  }

  /// Returns only changes affecting [path].
  List<WorkspaceFileChange> forPath(String path) {
    return List.unmodifiable(
      _changes.where((change) => change.path == path),
    );
  }

  /// Returns a new diff containing only the requested change types.
  WorkspaceDiff whereTypes(
    Set<WorkspaceChangeType> types,
  ) {
    return WorkspaceDiff(
      changes: _changes
          .where((change) => types.contains(change.type))
          .toList(growable: false),
    );
  }

  @override
  String toString() {
    return 'WorkspaceDiff('
        'changes: $length, '
        'additions: $additions, '
        'modifications: $modifications, '
        'deletions: $deletions'
        ')';
  }
}
