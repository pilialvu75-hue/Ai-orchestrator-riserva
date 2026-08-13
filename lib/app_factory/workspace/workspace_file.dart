/// Rappresenta un singolo file gestito dal cantiere AI.
///
/// Il modello è volutamente indipendente da GitHub e dal filesystem.
/// Serve come oggetto comune tra:
///
///   repository → VirtualWorkspace → AI → diff → validator → Git
///
/// Non contiene operazioni di I/O.
final class WorkspaceFile {
  const WorkspaceFile({
    required this.path,
    required this.content,
    this.status = WorkspaceFileStatus.unchanged,
    this.originalContent,
  });

  /// Percorso relativo alla root del repository.
  final String path;

  /// Contenuto attualmente presente nel workspace virtuale.
  final String content;

  /// Contenuto originale letto dal repository, se disponibile.
  ///
  /// È null per un file creato ex-novo.
  final String? originalContent;

  /// Stato del file rispetto all'originale.
  final WorkspaceFileStatus status;

  /// True quando il file è stato modificato rispetto allo stato iniziale.
  bool get isModified =>
      status == WorkspaceFileStatus.modified ||
      status == WorkspaceFileStatus.added ||
      status == WorkspaceFileStatus.deleted;

  /// True quando il file è nuovo.
  bool get isNew => status == WorkspaceFileStatus.added;

  /// True quando il file è stato eliminato.
  bool get isDeleted => status == WorkspaceFileStatus.deleted;

  /// True quando il file non presenta modifiche.
  bool get isUnchanged => status == WorkspaceFileStatus.unchanged;

  /// Numero di caratteri del contenuto corrente.
  int get contentLength => content.length;

  /// Numero di caratteri del contenuto originale.
  int get originalContentLength => originalContent?.length ?? 0;

  /// Crea una copia con i valori specificati modificati.
  WorkspaceFile copyWith({
    String? path,
    String? content,
    String? originalContent,
    WorkspaceFileStatus? status,
  }) {
    return WorkspaceFile(
      path: path ?? this.path,
      content: content ?? this.content,
      originalContent: originalContent ?? this.originalContent,
      status: status ?? this.status,
    );
  }

  /// Crea una rappresentazione del file dopo una modifica.
  ///
  /// Il calcolo dello stato è centralizzato qui per evitare che i vari
  /// livelli dell'applicazione implementino regole differenti.
  WorkspaceFile withContent(String newContent) {
    final newStatus = _calculateStatus(
      originalContent: originalContent,
      currentContent: newContent,
    );

    return WorkspaceFile(
      path: path,
      content: newContent,
      originalContent: originalContent,
      status: newStatus,
    );
  }

  /// Crea un file nuovo nel workspace.
  factory WorkspaceFile.newFile({
    required String path,
    required String content,
  }) {
    return WorkspaceFile(
      path: path,
      content: content,
      originalContent: null,
      status: WorkspaceFileStatus.added,
    );
  }

  /// Crea un file proveniente dal repository senza modifiche.
  factory WorkspaceFile.fromRepository({
    required String path,
    required String content,
  }) {
    return WorkspaceFile(
      path: path,
      content: content,
      originalContent: content,
      status: WorkspaceFileStatus.unchanged,
    );
  }

  /// Crea un file marcato come eliminato.
  ///
  /// Manteniamo il contenuto originale perché può essere necessario
  /// per produrre un diff o per effettuare un ripristino.
  factory WorkspaceFile.deleted({
    required String path,
    required String originalContent,
  }) {
    return WorkspaceFile(
      path: path,
      content: '',
      originalContent: originalContent,
      status: WorkspaceFileStatus.deleted,
    );
  }

  static WorkspaceFileStatus _calculateStatus({
    required String? originalContent,
    required String currentContent,
  }) {
    if (originalContent == null) {
      return WorkspaceFileStatus.added;
    }

    if (originalContent == currentContent) {
      return WorkspaceFileStatus.unchanged;
    }

    return WorkspaceFileStatus.modified;
  }

  @override
  String toString() {
    return 'WorkspaceFile('
        'path=$path, '
        'status=${status.name}, '
        'contentLength=$contentLength'
        ')';
  }
}

/// Stato di un file all'interno del VirtualWorkspace.
enum WorkspaceFileStatus {
  /// File presente nel repository e non modificato.
  unchanged,

  /// File esistente modificato dall'AI o dall'utente.
  modified,

  /// File creato nel workspace.
  added,

  /// File esistente marcato per l'eliminazione.
  deleted,
}
