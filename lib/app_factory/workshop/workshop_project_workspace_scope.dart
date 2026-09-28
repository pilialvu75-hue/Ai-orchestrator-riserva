import 'dart:convert';

import 'package:path/path.dart' as p;

/// Deterministic filesystem scope for one Cantiere production project.
///
/// The encoded segment is derived from the exact project id and cannot contain
/// path separators or traversal tokens. Each project therefore owns a stable
/// physical directory across app restarts and recovery.
abstract final class WorkshopProjectWorkspaceScope {
  const WorkshopProjectWorkspaceScope._();

  static String resolve({
    required String workspaceRootPath,
    required String projectId,
  }) {
    final root = workspaceRootPath.trim();
    final id = projectId.trim();

    if (root.isEmpty) {
      throw ArgumentError.value(
        workspaceRootPath,
        'workspaceRootPath',
        'Workspace root path cannot be empty.',
      );
    }
    if (id.isEmpty) {
      throw ArgumentError.value(
        projectId,
        'projectId',
        'Project id cannot be empty.',
      );
    }

    final encoded = utf8
        .encode(id)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();

    return p.join(root, 'projects', 'project-$encoded');
  }
}
