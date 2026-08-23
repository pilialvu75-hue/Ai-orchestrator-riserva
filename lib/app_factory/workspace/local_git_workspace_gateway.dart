import 'dart:io';

import 'git_workspace_gateway.dart';

/// Gateway locale per il Workspace del Cantiere.
///
/// Questo adapter collega il contratto [GitWorkspaceGateway] a una
/// directory locale del dispositivo.
///
/// È volutamente limitato alla parte di workspace:
///
///   directory locale
///        ↓
///   LocalGitWorkspaceGateway
///        ↓
///   VirtualWorkspace
///        ↓
///   WorkspaceSession
///
/// Le operazioni Git remote (branch, commit, push e Pull Request) non
/// vengono simulate e non vengono eseguite automaticamente.
///
/// In questa prima fase il gateway serve a permettere al Cantiere di:
/// - aprire un progetto locale;
/// - leggere i file;
/// - elencare i file;
/// - verificare l'esistenza di un file;
/// - scrivere file dopo l'approvazione del VirtualWorkspace;
/// - eliminare file dopo l'approvazione del VirtualWorkspace.
///
/// Le operazioni Git vere e proprie verranno collegate in un anello
/// successivo senza cambiare il contratto superiore.
final class LocalGitWorkspaceGateway implements GitWorkspaceGateway {
  LocalGitWorkspaceGateway({
    required String rootPath,
    this.includeHiddenFiles = false,
    this.maxFileSizeBytes = 10 * 1024 * 1024,
  }) : _rootDirectory = Directory(rootPath);

  final Directory _rootDirectory;

  /// Se true, include file e directory nascosti nell'elenco.
  ///
  /// Per il Cantiere è false di default per evitare di caricare
  /// accidentalmente metadati e directory tecniche non necessarie.
  final bool includeHiddenFiles;

  /// Dimensione massima di un file leggibile dal VirtualWorkspace.
  ///
  /// Evita che un singolo file binario o generato accidentalmente
  /// saturi la memoria dell'app.
  final int maxFileSizeBytes;

  Directory get rootDirectory => _rootDirectory;

  @override
  Future<GitWorkspaceInfo> openWorkspace() async {
    await _ensureRootDirectory();

    return GitWorkspaceInfo(
      repository: _rootDirectory.path,
      branch: 'local',
    );
  }

  @override
  Future<String?> readFile(String path) async {
    final file = await _resolveFile(path);

    if (!await file.exists()) {
      return null;
    }

    final stat = await file.stat();

    if (stat.type != FileSystemEntityType.file) {
      return null;
    }

    if (stat.size > maxFileSizeBytes) {
      throw StateError(
        'File "$path" exceeds the maximum supported size '
        'of $maxFileSizeBytes bytes.',
      );
    }

    return file.readAsString();
  }

  @override
  Future<bool> fileExists(String path) async {
    final file = await _resolveFile(path);
    return file.exists();
  }

  @override
  Future<List<String>> listFiles({
    String? directory,
  }) async {
    await _ensureRootDirectory();

    final Directory startDirectory;

    if (directory == null || directory.trim().isEmpty) {
      startDirectory = _rootDirectory;
    } else {
      startDirectory = await _resolveDirectory(directory);
    }

    if (!await startDirectory.exists()) {
      return const <String>[];
    }

    final result = <String>[];

    await for (final entity in startDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }

      final relativePath = _relativePath(entity.path);

      if (relativePath.isEmpty) {
        continue;
      }

      if (!_shouldIncludePath(relativePath)) {
        continue;
      }

      final stat = await entity.stat();

      if (stat.type != FileSystemEntityType.file) {
        continue;
      }

      if (stat.size > maxFileSizeBytes) {
        continue;
      }

      result.add(relativePath);
    }

    result.sort();
    return List.unmodifiable(result);
  }

  @override
  Future<void> createBranch(String branchName) async {
    throw UnsupportedError(
      'LocalGitWorkspaceGateway does not create Git branches yet. '
      'Branch management will be connected by a later Git backend.',
    );
  }

  @override
  Future<void> writeFile({
    required String path,
    required String content,
  }) async {
    final file = await _resolveFile(path);

    await file.parent.create(recursive: true);
    await file.writeAsString(
      content,
      flush: true,
    );
  }

  @override
  Future<void> deleteFile(String path) async {
    final file = await _resolveFile(path);

    if (!await file.exists()) {
      return;
    }

    final stat = await file.stat();

    if (stat.type != FileSystemEntityType.file) {
      throw StateError(
        'Cannot delete workspace path "$path" because it is not a file.',
      );
    }

    await file.delete();
  }

  @override
  Future<GitWorkspaceDiff> getDiff() async {
    // Il diff autorevole del Cantiere viene costruito da VirtualWorkspace.
    //
    // Il filesystem locale non mantiene qui una seconda copia dello stato
    // precedente, quindi non inventiamo un diff confrontando file senza
    // un baseline. Questo metodo restituisce un workspace locale neutro.
    return const GitWorkspaceDiff(
      files: <GitWorkspaceFileChange>[],
    );
  }

  @override
  Future<String> commit(String message) async {
    throw UnsupportedError(
      'LocalGitWorkspaceGateway does not create Git commits yet. '
      'Git commit support will be added through a dedicated Git backend.',
    );
  }

  @override
  Future<void> push() async {
    throw UnsupportedError(
      'LocalGitWorkspaceGateway does not push to a remote repository. '
      'Remote Git support will be added through a dedicated Git backend.',
    );
  }

  @override
  Future<String> createPullRequest({
    required String title,
    required String body,
    required String headBranch,
    required String baseBranch,
  }) async {
    throw UnsupportedError(
      'LocalGitWorkspaceGateway does not create Pull Requests yet. '
      'Pull Request support will be added through a dedicated remote backend.',
    );
  }

  Future<void> _ensureRootDirectory() async {
    final exists = await _rootDirectory.exists();

    if (!exists) {
      throw StateError(
        'Workspace directory does not exist: ${_rootDirectory.path}',
      );
    }

    final stat = await _rootDirectory.stat();

    if (stat.type != FileSystemEntityType.directory) {
      throw StateError(
        'Workspace root is not a directory: ${_rootDirectory.path}',
      );
    }
  }

  Future<Directory> _resolveDirectory(String path) async {
    final normalized = _validateRelativePath(path);
    final directory = Directory(
      _joinRootAndRelativePath(normalized),
    );

    final resolvedRoot = _normalizeAbsolutePath(
      _rootDirectory.absolute.path,
    );

    final resolvedDirectory = _normalizeAbsolutePath(
      directory.absolute.path,
    );

    _ensureInsideRoot(
      resolvedRoot,
      resolvedDirectory,
      path,
    );

    return directory;
  }

  Future<File> _resolveFile(String path) async {
    final normalized = _validateRelativePath(path);

    final file = File(
      _joinRootAndRelativePath(normalized),
    );

    final resolvedRoot = _normalizeAbsolutePath(
      _rootDirectory.absolute.path,
    );

    final resolvedFile = _normalizeAbsolutePath(
      file.absolute.path,
    );

    _ensureInsideRoot(
      resolvedRoot,
      resolvedFile,
      path,
    );

    return file;
  }

  String _validateRelativePath(String path) {
    final normalized = path.trim().replaceAll('\\', '/');

    if (normalized.isEmpty) {
      throw ArgumentError.value(
        path,
        'path',
        'Workspace path cannot be empty.',
      );
    }

    if (normalized.startsWith('/') ||
        normalized.startsWith('~/') ||
        _looksLikeWindowsAbsolutePath(normalized)) {
      throw ArgumentError.value(
        path,
        'path',
        'Workspace paths must be relative to the workspace root.',
      );
    }

    final segments = normalized.split('/');

    if (segments.any((segment) => segment == '..')) {
      throw ArgumentError.value(
        path,
        'path',
        'Workspace paths cannot escape the workspace root.',
      );
    }

    final cleaned = segments
        .where((segment) => segment.isNotEmpty && segment != '.')
        .join('/');

    if (cleaned.isEmpty) {
      throw ArgumentError.value(
        path,
        'path',
        'Workspace path cannot be empty.',
      );
    }

    return cleaned;
  }

  bool _looksLikeWindowsAbsolutePath(String path) {
    if (path.length < 3) {
      return false;
    }

    final first = path.codeUnitAt(0);
    final second = path.codeUnitAt(1);

    final isLetter =
        (first >= 65 && first <= 90) ||
        (first >= 97 && first <= 122);

    return isLetter && second == 58;
  }

  void _ensureInsideRoot(
    String root,
    String candidate,
    String originalPath,
  ) {
    final normalizedRoot = _normalizeAbsolutePath(root);
    final normalizedCandidate = _normalizeAbsolutePath(candidate);

    if (normalizedCandidate == normalizedRoot) {
      return;
    }

    final rootPrefix = normalizedRoot.endsWith('/')
        ? normalizedRoot
        : '$normalizedRoot/';

    if (!normalizedCandidate.startsWith(rootPrefix)) {
      throw ArgumentError.value(
        originalPath,
        'path',
        'Workspace path escapes the workspace root.',
      );
    }
  }

  String _joinRootAndRelativePath(String relativePath) {
    final separator = Platform.pathSeparator;

    final nativeRelativePath = relativePath.replaceAll(
      '/',
      separator,
    );

    return '${_rootDirectory.path}$separator$nativeRelativePath';
  }

  String _relativePath(String absolutePath) {
    final root = _normalizeAbsolutePath(
      _rootDirectory.absolute.path,
    );

    final file = _normalizeAbsolutePath(
      absolutePath,
    );

    final prefix = root.endsWith('/') ? root : '$root/';

    if (!file.startsWith(prefix)) {
      return '';
    }

    return file
        .substring(prefix.length)
        .replaceAll('\\', '/');
  }

  bool _shouldIncludePath(String relativePath) {
    if (includeHiddenFiles) {
      return true;
    }

    final segments = relativePath.split('/');

    for (final segment in segments) {
      if (segment.startsWith('.')) {
        return false;
      }

      // Directory Git interna: il Cantiere non deve caricarne
      // ricorsivamente il contenuto nel VirtualWorkspace.
      if (segment == '.git') {
        return false;
      }
    }

    return true;
  }

  String _normalizeAbsolutePath(String path) {
    var normalized = path.replaceAll('\\', '/');

    while (normalized.contains('//')) {
      normalized = normalized.replaceAll('//', '/');
    }

    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(
        0,
        normalized.length - 1,
      );
    }

    return normalized;
  }
}
