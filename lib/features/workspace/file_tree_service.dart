import 'dart:io';

class WorkspaceFileNode {
  const WorkspaceFileNode({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.children = const <WorkspaceFileNode>[],
  });

  final String path;
  final String name;
  final bool isDirectory;
  final List<WorkspaceFileNode> children;
}

class FileTreeService {
  WorkspaceFileNode buildTree(
    String rootPath, {
    int maxDepth = 4,
  }) {
    final root = Directory(rootPath);
    if (!root.existsSync()) {
      throw FileSystemException('Workspace root does not exist', rootPath);
    }
    return _buildNode(root, depth: 0, maxDepth: maxDepth);
  }

  WorkspaceFileNode _buildNode(
    FileSystemEntity entity, {
    required int depth,
    required int maxDepth,
  }) {
    final isDirectory = entity is Directory;
    final name = entity.uri.pathSegments.isEmpty
        ? entity.path
        : entity.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .last;
    if (!isDirectory || depth >= maxDepth) {
      return WorkspaceFileNode(
        path: entity.path,
        name: name,
        isDirectory: isDirectory,
      );
    }
    final dir = entity;
    final children = <WorkspaceFileNode>[];
    final listed = dir.listSync(followLinks: false);
    listed.sort((a, b) => a.path.compareTo(b.path));
    for (final child in listed) {
      if (_isHiddenPath(child.path)) continue;
      children.add(_buildNode(child, depth: depth + 1, maxDepth: maxDepth));
    }
    return WorkspaceFileNode(
      path: entity.path,
      name: name,
      isDirectory: true,
      children: children,
    );
  }

  bool _isHiddenPath(String path) {
    final segments = path.split(Platform.pathSeparator);
    return segments.any((segment) => segment.startsWith('.'));
  }
}

