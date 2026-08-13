/// Contratto astratto per il ponte tra AI Engineering Workspace
/// e un repository Git.
///
/// IMPORTANTE:
/// - questo livello NON contiene implementazioni GitHub;
/// - non modifica direttamente il filesystem reale;
/// - non contiene token o credenziali;
/// - non dipende dall'interfaccia grafica.
///
/// L'obiettivo è creare un confine stabile tra il motore AI e il
/// sistema di versionamento. In futuro l'implementazione potrà essere
/// GitHub, GitLab, repository locale o un altro backend.
///
/// La pipeline prevista è:
///
///   AI
///    ↓
///   CodeOrchestrator
///    ↓
///   VirtualWorkspace
///    ↓
///   GitWorkspaceGateway
///    ↓
///   GitHub / altro backend
///
/// Nessuna implementazione concreta deve bypassare VirtualWorkspace
/// per applicare direttamente modifiche generate dall'AI.
abstract interface class GitWorkspaceGateway {
  /// Apre una sessione sul repository.
  ///
  /// Non deve modificare il repository.
  Future<GitWorkspaceInfo> openWorkspace();

  /// Legge il contenuto di un file dal workspace remoto.
  ///
  /// [path] deve essere relativo alla root del repository.
  Future<String?> readFile(String path);

  /// Verifica se un file esiste nel workspace remoto.
  Future<bool> fileExists(String path);

  /// Restituisce l'elenco dei file richiesti dal workspace.
  ///
  /// Se [directory] è null, la ricerca parte dalla root del repository.
  Future<List<String>> listFiles({
    String? directory,
  });

  /// Crea una nuova branch.
  ///
  /// Questa operazione NON deve essere usata automaticamente dall'LLM
  /// senza una decisione esplicita del livello orchestratore.
  Future<void> createBranch(String branchName);

  /// Scrive un file nel workspace remoto.
  ///
  /// Questa è un'operazione MUTANTE.
  /// Deve essere utilizzata solamente dopo che la patch è stata:
  ///
  /// 1. generata;
  /// 2. verificata;
  /// 3. validata;
  /// 4. autorizzata dal livello superiore.
  Future<void> writeFile({
    required String path,
    required String content,
  });

  /// Elimina un file dal workspace remoto.
  ///
  /// Operazione mutante e quindi soggetta agli stessi guardrail
  /// di [writeFile].
  Future<void> deleteFile(String path);

  /// Restituisce il diff corrente del workspace.
  ///
  /// Il risultato concreto verrà definito quando collegheremo
  /// questo contratto al VirtualWorkspace e al diff builder già
  /// presenti nel progetto.
  Future<GitWorkspaceDiff> getDiff();

  /// Crea un commit.
  ///
  /// Questa operazione deve essere esplicitamente autorizzata
  /// dall'orchestratore.
  Future<String> commit(String message);

  /// Pubblica la branch remota.
  ///
  /// Deve essere chiamata solamente dopo una validazione riuscita.
  Future<void> push();

  /// Crea una Pull Request.
  ///
  /// L'implementazione concreta sarà introdotta in una fase successiva.
  Future<String> createPullRequest({
    required String title,
    required String body,
    required String headBranch,
    required String baseBranch,
  });
}

/// Informazioni non mutanti relative al workspace remoto.
final class GitWorkspaceInfo {
  const GitWorkspaceInfo({
    required this.repository,
    required this.branch,
    this.commitSha,
  });

  final String repository;
  final String branch;
  final String? commitSha;

  @override
  String toString() {
    return 'GitWorkspaceInfo('
        'repository=$repository, '
        'branch=$branch, '
        'commitSha=$commitSha'
        ')';
  }
}

/// Diff astratto prodotto dal workspace.
///
/// Manteniamo volutamente questo modello minimale nella prima fase.
/// Il collegamento con FileDiff/WorkspaceDiffBuilder esistenti verrà
/// fatto nel livello di integrazione, senza duplicare la logica già
/// presente nel progetto.
final class GitWorkspaceDiff {
  const GitWorkspaceDiff({
    required this.files,
  });

  final List<GitWorkspaceFileChange> files;

  bool get isEmpty => files.isEmpty;
}

/// Modifica di un singolo file nel workspace.
final class GitWorkspaceFileChange {
  const GitWorkspaceFileChange({
    required this.path,
    required this.changeType,
  });

  final String path;
  final GitWorkspaceChangeType changeType;
}

/// Tipo di modifica rilevata.
enum GitWorkspaceChangeType {
  added,
  modified,
  deleted,
  renamed,
}
