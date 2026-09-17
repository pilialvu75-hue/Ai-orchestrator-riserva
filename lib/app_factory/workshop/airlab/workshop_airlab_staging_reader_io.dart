import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'workshop_airlab_workspace_promoter.dart';

/// Native read-only implementation for AIrLab staging promotion.
///
/// This reader never receives the real repository root. It only inspects the
/// staging root assigned by Cantiere and rejects path/symlink escape before
/// returning staged text to the platform-agnostic promoter.
final class WorkshopAirLabIoStagingReader
    implements WorkshopAirLabStagingReader {
  const WorkshopAirLabIoStagingReader({
    this.maxFileBytes = 256 * 1024,
  });

  final int maxFileBytes;

  @override
  Future<WorkshopAirLabStagedFile> inspect({
    required String stagingRoot,
    required String relativePath,
  }) async {
    final normalizedPath = _normalizeRelativePath(relativePath);
    final rootValue = stagingRoot.trim();
    if (rootValue.isEmpty) {
      throw const WorkshopAirLabPromotionException(
        'Cantiere staging root is empty.',
        code: 'staging_root_invalid',
      );
    }

    final rootPath = p.normalize(p.absolute(rootValue));
    final rootType =
        await FileSystemEntity.type(rootPath, followLinks: false);
    if (rootType == FileSystemEntityType.link) {
      throw WorkshopAirLabPromotionException(
        'Cantiere staging root cannot be a symbolic link.',
        code: 'staging_root_symlink',
        path: rootValue,
      );
    }
    if (rootType != FileSystemEntityType.directory) {
      throw WorkshopAirLabPromotionException(
        'Cantiere staging root must be an existing directory.',
        code: 'staging_root_invalid',
        path: rootValue,
      );
    }

    try {
      final rootDirectory = Directory(rootPath);
      final canonicalRoot =
          p.normalize(await rootDirectory.resolveSymbolicLinks());
      final targetPath = p.normalize(
        p.joinAll(<String>[rootPath, ...normalizedPath.split('/')]),
      );
      final absoluteTarget = p.normalize(p.absolute(targetPath));
      if (!_isInside(rootPath, absoluteTarget)) {
        throw WorkshopAirLabPromotionException(
          'AIrLab staged path escapes the assigned staging root.',
          code: 'path_escape',
          path: normalizedPath,
        );
      }

      await _validateComponents(
        rootPath: rootPath,
        canonicalRoot: canonicalRoot,
        relativePath: normalizedPath,
      );

      final targetType =
          await FileSystemEntity.type(targetPath, followLinks: false);
      if (targetType == FileSystemEntityType.notFound) {
        return const WorkshopAirLabStagedFile.missing();
      }
      if (targetType == FileSystemEntityType.link) {
        throw WorkshopAirLabPromotionException(
          'AIrLab promotion cannot read a symbolic-link target.',
          code: 'symlink_target_forbidden',
          path: normalizedPath,
        );
      }
      if (targetType != FileSystemEntityType.file) {
        throw WorkshopAirLabPromotionException(
          'AIrLab staged changed path must resolve to a file or be absent.',
          code: 'staged_path_type_invalid',
          path: normalizedPath,
        );
      }

      final file = File(targetPath);
      final resolvedTarget = p.normalize(await file.resolveSymbolicLinks());
      if (!_isInside(canonicalRoot, resolvedTarget)) {
        throw WorkshopAirLabPromotionException(
          'AIrLab staged file resolves outside the assigned staging root.',
          code: 'symlink_escape',
          path: normalizedPath,
        );
      }

      final length = await file.length();
      if (length > maxFileBytes) {
        throw WorkshopAirLabPromotionException(
          'AIrLab staged file exceeds the promotion read limit.',
          code: 'staged_file_too_large',
          path: normalizedPath,
        );
      }

      final bytes = await file.readAsBytes();
      if (bytes.length > maxFileBytes) {
        throw WorkshopAirLabPromotionException(
          'AIrLab staged file exceeds the promotion read limit.',
          code: 'staged_file_too_large',
          path: normalizedPath,
        );
      }

      String content;
      try {
        content = utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        throw WorkshopAirLabPromotionException(
          'AIrLab staged file is not valid UTF-8 text.',
          code: 'staged_file_not_utf8',
          path: normalizedPath,
        );
      }

      return WorkshopAirLabStagedFile.present(content);
    } on WorkshopAirLabPromotionException {
      rethrow;
    } on FileSystemException catch (error) {
      throw WorkshopAirLabPromotionException(
        'Native AIrLab staging read failed: ${error.message}',
        code: 'staging_filesystem_error',
        path: error.path ?? normalizedPath,
      );
    }
  }

  Future<void> _validateComponents({
    required String rootPath,
    required String canonicalRoot,
    required String relativePath,
  }) async {
    var current = rootPath;
    final segments = relativePath.split('/');
    for (var index = 0; index < segments.length; index += 1) {
      current = p.join(current, segments[index]);
      final type =
          await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return;
      }
      if (type == FileSystemEntityType.link) {
        throw WorkshopAirLabPromotionException(
          'AIrLab staged path crosses a symbolic link.',
          code: 'symlink_escape',
          path: relativePath,
        );
      }

      final resolved = type == FileSystemEntityType.directory
          ? await Directory(current).resolveSymbolicLinks()
          : await File(current).resolveSymbolicLinks();
      if (!_isInside(canonicalRoot, p.normalize(resolved))) {
        throw WorkshopAirLabPromotionException(
          'AIrLab staged path resolves outside the assigned staging root.',
          code: 'symlink_escape',
          path: relativePath,
        );
      }

      // A non-final component must be a directory.
      if (index < segments.length - 1 &&
          type != FileSystemEntityType.directory) {
        throw WorkshopAirLabPromotionException(
          'AIrLab staged path crosses a non-directory component.',
          code: 'staged_path_type_invalid',
          path: relativePath,
        );
      }
    }
  }

  static bool _isInside(String root, String candidate) {
    return p.equals(root, candidate) || p.isWithin(root, candidate);
  }
}

String _normalizeRelativePath(String rawPath) {
  final value = rawPath.trim().replaceAll('\\', '/');
  if (value.isEmpty) {
    throw const WorkshopAirLabPromotionException(
      'AIrLab staging read path is empty.',
      code: 'empty_path',
    );
  }
  if (value.contains('\u0000')) {
    throw WorkshopAirLabPromotionException(
      'AIrLab staging read path contains a null byte.',
      code: 'invalid_path',
      path: rawPath,
    );
  }
  if (value.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(value)) {
    throw WorkshopAirLabPromotionException(
      'AIrLab staging read path must be relative.',
      code: 'absolute_path_forbidden',
      path: rawPath,
    );
  }

  final segments = value.split('/');
  if (segments.any((segment) =>
      segment.isEmpty || segment == '.' || segment == '..')) {
    throw WorkshopAirLabPromotionException(
      'AIrLab staging read path contains traversal or empty segments.',
      code: 'path_traversal',
      path: rawPath,
    );
  }

  return segments.join('/');
}
