import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';

/// Workspace virtuale utilizzato dal cantiere AI.
///
/// Questo livello è volutamente separato dal repository reale.
///
/// Flusso previsto:
///
///   repository reale
///          ↓
///   VirtualWorkspace
///          ↓
///   modifiche AI
///          ↓
///   diff
///          ↓
///   validazione
///          ↓
///   approvazione
///          ↓
///   GitWorkspaceGateway
///
/// Regola fondamentale:
/// VirtualWorkspace NON modifica direttamente GitHub o il filesystem
/// reale.
///
/// Questo permette all'LLM di:
/// - leggere file;
/// - proporre modifiche;
/// - creare nuovi file;
/// - eliminare file;
/// - confrontare lo stato precedente e quello nuovo;
/// senza poter alterare immediatamente il repository reale.
final class VirtualWorkspace {
  VirtualWorkspace({
    required GitWorkspaceGateway gateway,
  }) : _gateway = gateway;

  final GitWorkspaceGateway _gateway;

  /// File caricati nello stato iniziale del workspace.
  final Map<String, String> _originalFiles = <String, String>{};

  /// Stato corrente del workspace virtuale.
  ///
  /// Contiene sia file originali sia modifiche generate localmente.
  final Map<String, String> _workingFiles = <String, String>{};

  /// File che risultano eliminati nello workspace virtuale.
  final Set<String> _deletedFiles = <String>{};

  bool _initialized = false;

  /// Indica se il workspace è stato inizializzato.
  bool get isInitialized => _initialized;

  /// Numero di file attualmente presenti nello workspace virtuale.
  int get fileCount => _workingFiles.length;

  /// Elenco dei percorsi presenti nello workspace.
  List<String> get paths {
    final result = _workingFiles.keys.toList()..sort();
    return List.unmodifiable(result);
  }

  /// Inizializza il workspace leggendo i file dal backend.
  ///
  /// L'operazione è esclusivamente di lettura.
  Future<void> initialize({
    String? directory,
  }) async {
    if (_initialized) {
      return;
    }

    final files = await _gateway.listFiles(
      directory: directory,
    );

    for (final path in files) {
      final normalizedPath = _normalizePath(path);

      if (normalizedPath.isEmpty) {
        continue;
      }

      final content = await _gateway.readFile(normalizedPath);

      if (content == null) {
        continue;
      }

      _originalFiles[normalizedPath] = content;
      _workingFiles[normalizedPath] = content;
    }

    _initialized = true;
  }

  /// Legge un file dallo stato corrente del workspace virtuale.
  ///
  /// Non accede nuovamente al repository remoto.
  String? read(String path) {
    final normalizedPath = _normalizePath(path);

    if (_deletedFiles.contains(normalizedPath)) {
      return null;
    }

    return _workingFiles[normalizedPath];
  }

  /// Verifica se un file esiste nello stato corrente.
  bool contains(String path) {
    final normalizedPath = _normalizePath(path);

    return !_deletedFiles.contains(normalizedPath) &&
        _workingFiles.containsKey(normalizedPath);
  }

  /// Inserisce o sostituisce un file nello workspace virtuale.
  ///
  /// NON modifica il repository reale.
  void write({
    required String path,
    required String content,
  }) {
    final normalizedPath = _validatePath(path);

    _workingFiles[normalizedPath] = content;
    _deletedFiles.remove(normalizedPath);
  }

  /// Elimina un file solamente dal workspace virtuale.
  ///
  /// NON modifica il repository reale.
  void delete(String path) {
    final normalizedPath = _validatePath(path);

    if (!_workingFiles.containsKey(normalizedPath) &&
        !_originalFiles.containsKey(normalizedPath)) {
      return;
    }

    _workingFiles.remove(normalizedPath);
    _deletedFiles.add(normalizedPath);
  }

  /// Ripristina un file allo stato originale.
  ///
  /// Utile per annullare una modifica generata dall'LLM.
  void revert(String path) {
    final normalizedPath = _validatePath(path);

    final original = _originalFiles[normalizedPath];

    if (original == null) {
      _workingFiles.remove(normalizedPath);
      _deletedFiles.remove(normalizedPath);
      return;
    }

    _workingFiles[normalizedPath] = original;
    _deletedFiles.remove(normalizedPath);
  }

  /// Annulla tutte le modifiche virtuali.
  ///
  /// Il repository reale non viene modificato.
  void revertAll() {
    _workingFiles
      ..clear()
      ..addAll(_originalFiles);

    _deletedFiles.clear();
  }

  /// Restituisce le modifiche correnti rispetto allo stato iniziale.
  List<GitWorkspaceFileChange> get changes {
    final result = <GitWorkspaceFileChange>[];

    final allPaths = <String>{
      ..._originalFiles.keys,
      ..._workingFiles.keys,
      ..._deletedFiles,
    };

    final sortedPaths = allPaths.toList()..sort();

    for (final path in sortedPaths) {
      final original = _originalFiles[path];
      final current = _workingFiles[path];

      if (_deletedFiles.contains(path)) {
        if (original != null) {
          result.add(
            GitWorkspaceFileChange(
              path: path,
              changeType: GitWorkspaceChangeType.deleted,
            ),
          );
        }
        continue;
      }

      if (original == null && current != null) {
        result.add(
          GitWorkspaceFileChange(
            path: path,
            changeType: GitWorkspaceChangeType.added,
          ),
        );
        continue;
      }

      if (original != current) {
        result.add(
          GitWorkspaceFileChange(
            path: path,
            changeType: GitWorkspaceChangeType.modified,
          ),
        );
      }
    }

    return List.unmodifiable(result);
  }

  /// Indica se il workspace contiene modifiche non ancora applicate.
  bool get hasChanges => changes.isNotEmpty;

  /// Numero di modifiche presenti.
  int get changeCount => changes.length;

  /// Restituisce una copia dello stato corrente.
  Map<String, String> get snapshot =>
      Map.unmodifiable(Map<String, String>.from(_workingFiles));

  /// Restituisce una copia dello stato originale.
  Map<String, String> get originalSnapshot =>
      Map.unmodifiable(Map<String, String>.from(_originalFiles));

  /// Produce il diff astratto del workspace.
  GitWorkspaceDiff buildDiff() {
    return GitWorkspaceDiff(
      files: changes,
    );
  }

  /// Applica le modifiche virtuali al repository reale.
  ///
  /// ATTENZIONE:
  /// questa è la prima operazione MUTANTE di questa classe.
  ///
  /// Deve essere chiamata solamente dal livello superiore dopo:
  /// - validazione;
  /// - controllo di sicurezza;
  /// - eventuali test;
  /// - approvazione esplicita.
  ///
  /// Non esegue commit o push automaticamente.
  Future<void> apply() async {
    if (!_initialized) {
      throw StateError(
        'VirtualWorkspace must be initialized before apply().',
      );
    }

    for (final change in changes) {
      switch (change.changeType) {
        case GitWorkspaceChangeType.added:
        case GitWorkspaceChangeType.modified:
          final content = _workingFiles[change.path];

          if (content == null) {
            throw StateError(
              'Missing working content for "${change.path}".',
            );
          }

          await _gateway.writeFile(
            path: change.path,
            content: content,
          );
          break;

        case GitWorkspaceChangeType.deleted:
          await _gateway.deleteFile(change.path);
          break;

        case GitWorkspaceChangeType.renamed:
          // Il rename non viene ancora sintetizzato automaticamente.
          // In questa fase rimane una responsabilità del livello
          // superiore che potrà rappresentarlo come delete + add.
          throw UnsupportedError(
            'Automatic rename application is not implemented yet.',
          );
      }
    }

    _synchronizeOriginalState();
  }

  /// Ricarica lo stato dal repository remoto.
  ///
  /// ATTENZIONE:
  /// questa operazione scarta le modifiche virtuali correnti.
  Future<void> reload({
    String? directory,
  }) async {
    _originalFiles.clear();
    _workingFiles.clear();
    _deletedFiles.clear();
    _initialized = false;

    await initialize(
      directory: directory,
    );
  }

  void _synchronizeOriginalState() {
    _originalFiles
      ..clear()
      ..addAll(_workingFiles);

    _deletedFiles.clear();
  }

  static String _normalizePath(String path) {
    return path.trim().replaceAll('\\', '/').replaceFirst(
          RegExp(r'^/+'),
          '',
        );
  }

  static String _validatePath(String path) {
    final normalized = _normalizePath(path);

    if (normalized.isEmpty) {
      throw ArgumentError.value(
        path,
        'path',
        'A workspace path cannot be empty.',
      );
    }

    if (normalized.startsWith('../') ||
        normalized == '..' ||
        normalized.contains('/../')) {
      throw ArgumentError.value(
        path,
        'path',
        'A workspace path cannot escape the repository root.',
      );
    }

    return normalized;
  }
}
