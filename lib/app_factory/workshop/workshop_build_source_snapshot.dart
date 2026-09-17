import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// One immutable source file captured from a Cantiere workspace for a build
/// executor. The snapshot contains bytes so text and binary project assets can
/// travel through the same guarded boundary.
final class WorkshopBuildSourceFile {
  const WorkshopBuildSourceFile({
    required this.relativePath,
    required this.bytes,
  });

  final String relativePath;
  final Uint8List bytes;

  int get sizeInBytes => bytes.lengthInBytes;
}

/// Bounded, deterministic representation of the source required by a build.
///
/// Transient outputs, VCS metadata and common secret/signing files are never
/// included. Build executors must treat this snapshot as untrusted project
/// input and still run their own validation gates.
final class WorkshopBuildSourceSnapshot {
  const WorkshopBuildSourceSnapshot({
    required this.rootPath,
    required this.files,
    required this.totalBytes,
  });

  final String rootPath;
  final List<WorkshopBuildSourceFile> files;
  final int totalBytes;

  bool contains(String relativePath) =>
      files.any((file) => file.relativePath == relativePath);
}

final class WorkshopBuildSourceSnapshotter {
  const WorkshopBuildSourceSnapshotter({
    this.maxFiles = 1024,
    this.maxFileBytes = 8 * 1024 * 1024,
    this.maxTotalBytes = 24 * 1024 * 1024,
  });

  final int maxFiles;
  final int maxFileBytes;
  final int maxTotalBytes;

  Future<WorkshopBuildSourceSnapshot> capture(String workspaceRootPath) async {
    if (maxFiles <= 0 || maxFileBytes <= 0 || maxTotalBytes <= 0) {
      throw StateError('Workshop build snapshot limits must be positive.');
    }

    final normalizedInput = workspaceRootPath.trim();
    if (normalizedInput.isEmpty) {
      throw ArgumentError.value(
        workspaceRootPath,
        'workspaceRootPath',
        'Workspace root cannot be empty.',
      );
    }

    final root = Directory(p.normalize(p.absolute(normalizedInput)));
    if (!await root.exists()) {
      throw StateError('Workshop build workspace does not exist.');
    }

    final captured = <WorkshopBuildSourceFile>[];
    var totalBytes = 0;

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Link) {
        throw StateError(
          'Workshop build source contains a symbolic link and cannot be '
          'exported safely.',
        );
      }
      if (entity is! File) continue;

      final relative = _portableRelative(root.path, entity.path);
      if (_excluded(relative)) continue;

      if (captured.length >= maxFiles) {
        throw StateError('Workshop build source exceeds the file-count limit.');
      }

      final length = await entity.length();
      if (length > maxFileBytes) {
        throw StateError(
          'Workshop build source file "$relative" exceeds the per-file limit.',
        );
      }
      if (totalBytes + length > maxTotalBytes) {
        throw StateError('Workshop build source exceeds the total-size limit.');
      }

      final bytes = await entity.readAsBytes();
      totalBytes += bytes.lengthInBytes;
      captured.add(
        WorkshopBuildSourceFile(
          relativePath: relative,
          bytes: Uint8List.fromList(bytes),
        ),
      );
    }

    captured.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    if (captured.isEmpty) {
      throw StateError('Workshop build workspace contains no exportable files.');
    }

    return WorkshopBuildSourceSnapshot(
      rootPath: root.path,
      files: List<WorkshopBuildSourceFile>.unmodifiable(captured),
      totalBytes: totalBytes,
    );
  }

  static String _portableRelative(String rootPath, String entityPath) {
    final relative = p.relative(entityPath, from: rootPath);
    if (relative == '.' || p.isAbsolute(relative)) {
      throw StateError('Workshop build source path escaped the workspace root.');
    }

    final portable = relative.replaceAll('\\', '/');
    final segments = portable.split('/');
    if (segments.isEmpty ||
        segments.any((segment) =>
            segment.isEmpty || segment == '.' || segment == '..')) {
      throw StateError('Workshop build source contains an unsafe path.');
    }
    return portable;
  }

  static bool _excluded(String relativePath) {
    final normalized = relativePath.toLowerCase();
    final segments = normalized.split('/');

    const excludedDirectories = <String>{
      '.git',
      '.dart_tool',
      '.gradle',
      '.idea',
      '.cantiere_artifacts',
      'build',
    };
    if (segments.any(excludedDirectories.contains)) return true;

    final name = segments.last;
    if (name == 'local.properties' ||
        name == 'key.properties' ||
        name == '.env' ||
        name.startsWith('.env.')) {
      return true;
    }
    if (name.endsWith('.jks') ||
        name.endsWith('.keystore') ||
        name.endsWith('.p12') ||
        name.endsWith('.pfx')) {
      return true;
    }

    return false;
  }
}
