import 'dart:io';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_source_snapshot.dart';
import 'package:path/path.dart' as p;

/// Result of staging a reusable source snapshot into the existing
/// VirtualWorkspace.
///
/// No real project file is written by this operation. The returned paths remain
/// subject to the normal Cantiere review, validation and explicit apply gate.
final class WorkshopReuseSourceStagingResult {
  const WorkshopReuseSourceStagingResult({
    required this.stagedPaths,
    required this.skippedExistingPaths,
    required this.rejectedPaths,
  });

  final List<String> stagedPaths;
  final List<String> skippedExistingPaths;
  final List<String> rejectedPaths;

  bool get hasChanges => stagedPaths.isNotEmpty;
}

/// Captures safe, text-only source snapshots from a verified Workshop project
/// and can later stage them into another task's VirtualWorkspace.
///
/// Snapshot capture intentionally excludes build outputs, dependency caches,
/// VCS metadata and common credential/signing files. Reuse never copies files
/// directly into the live project: [stageInto] writes only to VirtualWorkspace.
final class WorkshopReuseSourceSnapshotService {
  const WorkshopReuseSourceSnapshotService({
    this.maxFileSizeBytes = 2 * 1024 * 1024,
  });

  final int maxFileSizeBytes;

  static const Set<String> _excludedDirectories = <String>{
    '.git',
    '.dart_tool',
    '.gradle',
    '.idea',
    '.vscode',
    '.cache',
    'build',
    'node_modules',
    'coverage',
    'dist',
    'out',
    'pods',
    'deriveddata',
  };

  static const Set<String> _blockedFileNames = <String>{
    '.env',
    'key.properties',
    'local.properties',
    'gradle.properties',
    'google-services.json',
    'googleservice-info.plist',
  };

  static const Set<String> _blockedExtensions = <String>{
    '.jks',
    '.keystore',
    '.p12',
    '.pfx',
    '.pem',
    '.key',
    '.der',
  };

  static const Set<String> _allowedExtensions = <String>{
    '.dart',
    '.yaml',
    '.yml',
    '.json',
    '.md',
    '.txt',
    '.html',
    '.htm',
    '.css',
    '.scss',
    '.sass',
    '.js',
    '.mjs',
    '.cjs',
    '.ts',
    '.tsx',
    '.jsx',
    '.xml',
    '.gradle',
    '.kts',
    '.java',
    '.kt',
    '.swift',
    '.m',
    '.mm',
    '.h',
    '.hpp',
    '.c',
    '.cc',
    '.cpp',
    '.cmake',
    '.toml',
    '.ini',
    '.conf',
    '.properties',
    '.lock',
    '.sh',
    '.bat',
    '.ps1',
    '.sql',
    '.graphql',
    '.gql',
  };

  static const Set<String> _allowedExtensionlessNames = <String>{
    'gradlew',
    'makefile',
    'dockerfile',
    'license',
    'readme',
  };

  Future<WorkshopReuseSourceSnapshot> capture({
    required String assetId,
    required String workspaceRootPath,
    required String snapshotsRootPath,
    Iterable<String> preferredPaths = const <String>[],
  }) async {
    final normalizedAssetId = assetId.trim();
    if (normalizedAssetId.isEmpty) {
      throw ArgumentError.value(assetId, 'assetId', 'Cannot be empty.');
    }
    if (maxFileSizeBytes <= 0) {
      throw StateError('maxFileSizeBytes must be greater than zero.');
    }

    final workspaceRoot = Directory(workspaceRootPath).absolute;
    final snapshotsRoot = Directory(snapshotsRootPath).absolute;

    if (!await workspaceRoot.exists()) {
      throw StateError(
        'Workshop source workspace does not exist: ${workspaceRoot.path}',
      );
    }

    final normalizedWorkspace = _normalizeAbsolute(workspaceRoot.path);
    final normalizedSnapshots = _normalizeAbsolute(snapshotsRoot.path);
    if (_isSameOrInside(normalizedSnapshots, normalizedWorkspace)) {
      throw StateError(
        'Reuse snapshot storage must live outside the source workspace.',
      );
    }

    await snapshotsRoot.create(recursive: true);

    final safeDirectoryName = _safeAssetDirectoryName(normalizedAssetId);
    final finalDirectory = Directory(
      p.join(snapshotsRoot.path, safeDirectoryName),
    );
    final tempDirectory = Directory(
      '${finalDirectory.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );

    await tempDirectory.create(recursive: true);

    final preferred = preferredPaths
        .map(_normalizeRelative)
        .where((path) => path.isNotEmpty)
        .toSet();

    final copiedPaths = <String>[];
    var totalBytes = 0;

    try {
      await for (final entity in workspaceRoot.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;

        final relative = _normalizeRelative(
          p.relative(entity.path, from: workspaceRoot.path),
        );
        if (relative.isEmpty || !_isSafeReusablePath(relative)) continue;
        if (preferred.isNotEmpty && !preferred.contains(relative)) continue;

        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.size > maxFileSizeBytes) {
          continue;
        }

        String content;
        try {
          content = await entity.readAsString();
        } catch (_) {
          continue;
        }

        final destination = File(p.join(tempDirectory.path, relative));
        await destination.parent.create(recursive: true);
        await destination.writeAsString(content, flush: true);

        copiedPaths.add(relative);
        totalBytes += stat.size;
      }

      copiedPaths.sort();
      if (copiedPaths.isEmpty) {
        throw StateError(
          'No safe reusable source files were found for asset '
          '"$normalizedAssetId".',
        );
      }

      if (await finalDirectory.exists()) {
        await finalDirectory.delete(recursive: true);
      }
      await tempDirectory.rename(finalDirectory.path);
    } catch (_) {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
      rethrow;
    }

    return WorkshopReuseSourceSnapshot(
      assetId: normalizedAssetId,
      rootPath: finalDirectory.path,
      files: copiedPaths,
      totalBytes: totalBytes,
    );
  }

  Future<WorkshopReuseSourceStagingResult> stageInto({
    required WorkshopReuseSourceSnapshot snapshot,
    required WorkspaceSession session,
    bool overwriteExisting = false,
  }) async {
    if (!snapshot.isUsable) {
      throw StateError('Reusable source snapshot is not usable.');
    }
    if (!session.workspace.isInitialized) {
      throw StateError(
        'Workshop reuse staging requires an initialized VirtualWorkspace.',
      );
    }
    if (session.status != WorkspaceSessionStatus.ready &&
        session.status != WorkspaceSessionStatus.working) {
      throw StateError(
        'Workshop reuse staging is allowed only while the session is ready '
        'or working. Current status: ${session.status.name}.',
      );
    }

    final root = Directory(snapshot.rootPath).absolute;
    if (!await root.exists()) {
      throw StateError(
        'Reusable source snapshot directory is unavailable: ${root.path}',
      );
    }

    final normalizedRoot = _normalizeAbsolute(root.path);
    final staged = <String>[];
    final skipped = <String>[];
    final rejected = <String>[];

    for (final rawPath in snapshot.files) {
      final relative = _normalizeRelative(rawPath);
      if (relative.isEmpty || !_isSafeReusablePath(relative)) {
        rejected.add(rawPath);
        continue;
      }

      final file = File(p.join(root.path, relative)).absolute;
      final normalizedFile = _normalizeAbsolute(file.path);
      if (!_isSameOrInside(normalizedFile, normalizedRoot) ||
          !await file.exists()) {
        rejected.add(relative);
        continue;
      }

      if (!overwriteExisting && session.workspace.contains(relative)) {
        skipped.add(relative);
        continue;
      }

      String content;
      try {
        final stat = await file.stat();
        if (stat.size > maxFileSizeBytes) {
          rejected.add(relative);
          continue;
        }
        content = await file.readAsString();
      } catch (_) {
        rejected.add(relative);
        continue;
      }

      session.workspace.write(path: relative, content: content);
      staged.add(relative);
    }

    staged.sort();
    skipped.sort();
    rejected.sort();

    return WorkshopReuseSourceStagingResult(
      stagedPaths: List<String>.unmodifiable(staged),
      skippedExistingPaths: List<String>.unmodifiable(skipped),
      rejectedPaths: List<String>.unmodifiable(rejected),
    );
  }

  static bool isSafeReusablePath(String path) =>
      _isSafeReusablePath(_normalizeRelative(path));

  static bool _isSafeReusablePath(String relativePath) {
    if (relativePath.isEmpty ||
        relativePath.startsWith('/') ||
        relativePath == '..' ||
        relativePath.startsWith('../') ||
        relativePath.contains('/../')) {
      return false;
    }

    final segments = relativePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) return false;

    for (final segment in segments.take(segments.length - 1)) {
      if (_excludedDirectories.contains(segment.toLowerCase())) {
        return false;
      }
    }

    final fileName = segments.last.toLowerCase();
    if (fileName == '.env' || fileName.startsWith('.env.')) return false;
    if (_blockedFileNames.contains(fileName)) return false;

    final extension = p.extension(fileName).toLowerCase();
    if (_blockedExtensions.contains(extension)) return false;
    if (extension.isEmpty) {
      return _allowedExtensionlessNames.contains(fileName);
    }
    return _allowedExtensions.contains(extension);
  }

  static String _normalizeRelative(String path) {
    final normalized = path.trim().replaceAll('\\', '/');
    final segments = normalized
        .split('/')
        .where((segment) => segment.isNotEmpty && segment != '.')
        .toList(growable: false);
    return segments.join('/');
  }

  static String _safeAssetDirectoryName(String assetId) {
    final normalized = assetId
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    if (normalized.isEmpty) {
      return 'reuse-${assetId.hashCode.abs()}';
    }
    return normalized.length > 80 ? normalized.substring(0, 80) : normalized;
  }

  static String _normalizeAbsolute(String value) {
    var normalized = p.normalize(value).replaceAll('\\', '/');
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static bool _isSameOrInside(String child, String parent) =>
      child == parent || child.startsWith('$parent/');
}
