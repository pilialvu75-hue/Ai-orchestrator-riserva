import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:path/path.dart' as p;

import 'workshop_airlab_contract.dart';
import 'workshop_airlab_staging_materializer.dart';

/// Hard limits for one AIrLab staging transaction.
final class WorkshopAirLabStagingLimits {
  const WorkshopAirLabStagingLimits({
    this.maxOperations = 64,
    this.maxPerFilePayloadBytes = 256 * 1024,
    this.maxTotalPayloadBytes = 1024 * 1024,
  });

  final int maxOperations;
  final int maxPerFilePayloadBytes;
  final int maxTotalPayloadBytes;
}

/// Native filesystem implementation of the AIrLab staging boundary.
///
/// The entire operation set is validated before the first mutation. Every path
/// is relative to [stagingRoot], scope-checked, bounded, and checked for symlink
/// escape. This class never knows the real repository path and never performs a
/// promotion/apply operation.
final class WorkshopAirLabIoStagingMaterializer
    implements WorkshopAirLabStagingMaterializer {
  const WorkshopAirLabIoStagingMaterializer({
    this.limits = const WorkshopAirLabStagingLimits(),
  });

  final WorkshopAirLabStagingLimits limits;

  @override
  Future<WorkshopAirLabStagingResult> materialize({
    required String stagingRoot,
    required List<WorkshopAirLabFileOperation> operations,
    required WorkshopTaskFileScope fileScope,
  }) async {
    final rootValue = stagingRoot.trim();
    if (rootValue.isEmpty) {
      throw const WorkshopAirLabStagingException(
        'Cantiere staging root is empty.',
        code: 'staging_root_invalid',
      );
    }

    if (operations.length > limits.maxOperations) {
      throw WorkshopAirLabStagingException(
        'AIrLab proposed ${operations.length} operations; the maximum is ${limits.maxOperations}.',
        code: 'operation_limit_exceeded',
      );
    }

    final rootPath = p.normalize(p.absolute(rootValue));
    final rootType = await FileSystemEntity.type(rootPath, followLinks: false);
    if (rootType == FileSystemEntityType.link) {
      throw WorkshopAirLabStagingException(
        'Cantiere staging root cannot be a symbolic link.',
        code: 'staging_root_symlink',
        path: rootValue,
      );
    }
    if (rootType != FileSystemEntityType.notFound &&
        rootType != FileSystemEntityType.directory) {
      throw WorkshopAirLabStagingException(
        'Cantiere staging root must be a directory.',
        code: 'staging_root_invalid',
        path: rootValue,
      );
    }

    final rootDirectory = Directory(rootPath);
    try {
      if (!await rootDirectory.exists()) {
        await rootDirectory.create(recursive: true);
      }
      final canonicalRoot = p.normalize(await rootDirectory.resolveSymbolicLinks());
      final scope = _ScopePolicy(fileScope);
      final prepared = <_PreparedOperation>[];
      final seenPaths = <String>{};
      var totalPayloadBytes = 0;

      for (final operation in operations) {
        final relativePath = _normalizeOperationPath(operation.path);
        if (!seenPaths.add(relativePath)) {
          throw WorkshopAirLabStagingException(
            'AIrLab proposed more than one operation for the same path.',
            code: 'duplicate_operation_path',
            path: relativePath,
          );
        }

        scope.validateWritable(relativePath);

        final payloadBytes = _payloadBytes(operation, relativePath);
        if (payloadBytes > limits.maxPerFilePayloadBytes) {
          throw WorkshopAirLabStagingException(
            'AIrLab payload exceeds the per-file staging limit.',
            code: 'file_payload_limit_exceeded',
            path: relativePath,
          );
        }
        totalPayloadBytes += payloadBytes;
        if (totalPayloadBytes > limits.maxTotalPayloadBytes) {
          throw const WorkshopAirLabStagingException(
            'AIrLab payload exceeds the total staging limit.',
            code: 'total_payload_limit_exceeded',
          );
        }

        final targetPath = p.normalize(
          p.joinAll(<String>[rootPath, ...relativePath.split('/')]),
        );
        final absoluteTarget = p.normalize(p.absolute(targetPath));
        if (!_isInside(rootPath, absoluteTarget)) {
          throw WorkshopAirLabStagingException(
            'AIrLab path escapes the assigned staging root.',
            code: 'path_escape',
            path: relativePath,
          );
        }

        await _validateNoSymlinkEscape(
          rootPath: rootPath,
          canonicalRoot: canonicalRoot,
          relativePath: relativePath,
        );
        await _validateActionTarget(operation, targetPath, relativePath);

        prepared.add(
          _PreparedOperation(
            operation: operation,
            relativePath: relativePath,
            targetPath: targetPath,
          ),
        );
      }

      var created = 0;
      var updated = 0;
      var deleted = 0;
      final changedFiles = <String>[];

      for (final item in prepared) {
        await _validateNoSymlinkEscape(
          rootPath: rootPath,
          canonicalRoot: canonicalRoot,
          relativePath: item.relativePath,
        );

        switch (item.operation.action) {
          case WorkshopAirLabFileOperationAction.create:
            final file = File(item.targetPath);
            await file.parent.create(recursive: true);
            await _validateResolvedDirectory(
              file.parent,
              canonicalRoot,
              item.relativePath,
            );
            await file.writeAsString(
              item.operation.content!,
              mode: FileMode.write,
              flush: true,
            );
            created += 1;
            break;
          case WorkshopAirLabFileOperationAction.update:
            final file = File(item.targetPath);
            await file.writeAsString(
              item.operation.content!,
              mode: FileMode.write,
              flush: true,
            );
            updated += 1;
            break;
          case WorkshopAirLabFileOperationAction.delete:
            await File(item.targetPath).delete();
            deleted += 1;
            break;
        }
        changedFiles.add(item.relativePath);
      }

      return WorkshopAirLabStagingResult(
        changedFiles: List<String>.unmodifiable(changedFiles),
        createdCount: created,
        updatedCount: updated,
        deletedCount: deleted,
        totalPayloadBytes: totalPayloadBytes,
      );
    } on WorkshopAirLabStagingException {
      rethrow;
    } on FileSystemException catch (error) {
      throw WorkshopAirLabStagingException(
        'Native staging filesystem operation failed: ${error.message}',
        code: 'staging_filesystem_error',
        path: error.path,
      );
    }
  }

  int _payloadBytes(
    WorkshopAirLabFileOperation operation,
    String relativePath,
  ) {
    switch (operation.action) {
      case WorkshopAirLabFileOperationAction.create:
      case WorkshopAirLabFileOperationAction.update:
        final content = operation.content;
        if (content == null) {
          throw WorkshopAirLabStagingException(
            'AIrLab create/update operations require textual content.',
            code: 'operation_content_missing',
            path: relativePath,
          );
        }
        return utf8.encode(content).length;
      case WorkshopAirLabFileOperationAction.delete:
        if (operation.content != null) {
          throw WorkshopAirLabStagingException(
            'AIrLab delete operations cannot carry file content.',
            code: 'delete_content_forbidden',
            path: relativePath,
          );
        }
        return 0;
    }
  }

  Future<void> _validateActionTarget(
    WorkshopAirLabFileOperation operation,
    String targetPath,
    String relativePath,
  ) async {
    final type = await FileSystemEntity.type(targetPath, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw WorkshopAirLabStagingException(
        'AIrLab cannot operate on symbolic links.',
        code: 'symlink_target_forbidden',
        path: relativePath,
      );
    }

    switch (operation.action) {
      case WorkshopAirLabFileOperationAction.create:
        if (type != FileSystemEntityType.notFound) {
          throw WorkshopAirLabStagingException(
            'AIrLab create target already exists.',
            code: 'create_target_exists',
            path: relativePath,
          );
        }
        break;
      case WorkshopAirLabFileOperationAction.update:
      case WorkshopAirLabFileOperationAction.delete:
        if (type != FileSystemEntityType.file) {
          throw WorkshopAirLabStagingException(
            'AIrLab ${operation.action.name} target must be an existing file.',
            code: 'existing_file_required',
            path: relativePath,
          );
        }
        break;
    }
  }

  Future<void> _validateNoSymlinkEscape({
    required String rootPath,
    required String canonicalRoot,
    required String relativePath,
  }) async {
    var current = rootPath;
    for (final segment in relativePath.split('/')) {
      current = p.join(current, segment);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw WorkshopAirLabStagingException(
          'AIrLab path crosses a symbolic link.',
          code: 'symlink_escape',
          path: relativePath,
        );
      }
      if (type == FileSystemEntityType.notFound) {
        break;
      }

      final resolved = type == FileSystemEntityType.directory
          ? await Directory(current).resolveSymbolicLinks()
          : await File(current).resolveSymbolicLinks();
      if (!_isInside(canonicalRoot, p.normalize(resolved))) {
        throw WorkshopAirLabStagingException(
          'AIrLab path resolves outside the assigned staging root.',
          code: 'symlink_escape',
          path: relativePath,
        );
      }
    }
  }

  Future<void> _validateResolvedDirectory(
    Directory directory,
    String canonicalRoot,
    String relativePath,
  ) async {
    final resolved = p.normalize(await directory.resolveSymbolicLinks());
    if (!_isInside(canonicalRoot, resolved)) {
      throw WorkshopAirLabStagingException(
        'AIrLab parent directory resolves outside staging.',
        code: 'symlink_escape',
        path: relativePath,
      );
    }
  }

  static bool _isInside(String root, String candidate) {
    return p.equals(root, candidate) || p.isWithin(root, candidate);
  }
}

String _normalizeOperationPath(String rawPath) {
  final value = rawPath.trim().replaceAll('\\', '/');
  if (value.isEmpty) {
    throw const WorkshopAirLabStagingException(
      'AIrLab operation path is empty.',
      code: 'empty_path',
    );
  }
  if (value.contains('\u0000')) {
    throw WorkshopAirLabStagingException(
      'AIrLab operation path contains a null byte.',
      code: 'invalid_path',
      path: rawPath,
    );
  }
  if (value.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(value)) {
    throw WorkshopAirLabStagingException(
      'AIrLab operation path must be relative.',
      code: 'absolute_path_forbidden',
      path: rawPath,
    );
  }

  final segments = value.split('/');
  if (segments.any((segment) =>
      segment.isEmpty || segment == '.' || segment == '..')) {
    throw WorkshopAirLabStagingException(
      'AIrLab operation path contains traversal or empty segments.',
      code: 'path_traversal',
      path: rawPath,
    );
  }

  return segments.join('/');
}

final class _ScopePolicy {
  _ScopePolicy(WorkshopTaskFileScope scope)
      : allowed = _rules(scope.allowed),
        forbidden = _rules(scope.forbidden),
        readOnly = _rules(scope.readOnly);

  final List<_ScopeRule> allowed;
  final List<_ScopeRule> forbidden;
  final List<_ScopeRule> readOnly;

  void validateWritable(String path) {
    if (_matches(forbidden, path)) {
      throw WorkshopAirLabStagingException(
        'AIrLab path is forbidden by the Workshop task scope.',
        code: 'path_forbidden',
        path: path,
      );
    }
    if (_matches(readOnly, path)) {
      throw WorkshopAirLabStagingException(
        'AIrLab path is read-only in the Workshop task scope.',
        code: 'path_read_only',
        path: path,
      );
    }
    if (allowed.isEmpty || !_matches(allowed, path)) {
      throw WorkshopAirLabStagingException(
        'AIrLab path is outside the writable Workshop task scope.',
        code: 'path_not_allowed',
        path: path,
      );
    }
  }

  static List<_ScopeRule> _rules(List<String> values) {
    return List<_ScopeRule>.unmodifiable(values.map(_ScopeRule.parse));
  }

  static bool _matches(List<_ScopeRule> rules, String path) {
    return rules.any((rule) => rule.matches(path));
  }
}

final class _ScopeRule {
  const _ScopeRule(this.path, this.subtree);

  factory _ScopeRule.parse(String raw) {
    final trimmed = raw.trim().replaceAll('\\', '/');
    final subtree = trimmed.endsWith('/');
    final withoutTrailing = trimmed.replaceFirst(RegExp(r'/+$'), '');
    final normalized = _normalizeOperationPath(withoutTrailing);
    return _ScopeRule(normalized, subtree);
  }

  final String path;
  final bool subtree;

  bool matches(String candidate) {
    if (candidate == path) return true;
    return subtree && candidate.startsWith('$path/');
  }
}

final class _PreparedOperation {
  const _PreparedOperation({
    required this.operation,
    required this.relativePath,
    required this.targetPath,
  });

  final WorkshopAirLabFileOperation operation;
  final String relativePath;
  final String targetPath;
}
