import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workspace/virtual_workspace.dart';

/// Stato operativo di una sessione del Workspace.
///
/// La sessione rappresenta un singolo lavoro del Cantiere:
///
///   richiesta
///      ↓
///   workspace virtuale
///      ↓
///   modifiche AI
///      ↓
///   diff
///      ↓
///   review / validazione
///      ↓
///   approvazione
///      ↓
///   apply
///
/// La sessione NON decide quale LLM utilizzare e NON contiene UI.
///
/// Questo è intenzionale: il Cantiere deve poter cambiare modello,
/// provider o interfaccia senza dover riscrivere il workspace.
enum WorkspaceSessionStatus {
  created,
  loading,
  ready,
  working,
  review,
  validation,
  approved,
  applying,
  completed,
  blocked,
  cancelled,
}

/// Contesto immutabile di una sessione di lavoro.
///
/// Contiene la richiesta originale e, quando disponibile, il brief
/// proveniente dalla Chat Assistente/A-Team.
final class WorkspaceSessionContext {
  const WorkspaceSessionContext({
    required this.request,
    this.brief,
  });

  final WorkshopRequest request;
  final WorkshopBrief? brief;
}

/// Sessione principale del Cantiere.
///
/// Responsabilità:
///
/// - mantenere il contesto della richiesta;
/// - inizializzare il VirtualWorkspace;
/// - esporre lo stato del lavoro;
/// - produrre il diff corrente;
/// - impedire applicazioni accidentali;
/// - coordinare il passaggio tra le fasi del Cantiere.
///
/// NON è responsabile di:
///
/// - chiamare direttamente un LLM;
/// - modificare GitHub direttamente;
/// - fare commit automatici;
/// - fare push automatici;
/// - gestire la UI;
/// - gestire la Chat Assistente.
///
/// Questa separazione è fondamentale per mantenere indipendenti
/// Chat Assistente e Chat Cantiere.
final class WorkspaceSession {
  WorkspaceSession({
    required WorkshopRequest request,
    required GitWorkspaceGateway gateway,
    WorkshopBrief? brief,
  })  : context = WorkspaceSessionContext(
          request: request,
          brief: brief,
        ),
        workspace = VirtualWorkspace(
          gateway: gateway,
        );

  /// Contesto originale della sessione.
  final WorkspaceSessionContext context;

  /// Workspace virtuale associato alla sessione.
  final VirtualWorkspace workspace;

  WorkspaceSessionStatus _status = WorkspaceSessionStatus.created;

  String? _blockedReason;

  bool _applyApproved = false;

  /// Stato corrente della sessione.
  WorkspaceSessionStatus get status => _status;

  /// Indica se la sessione è stata bloccata.
  bool get isBlocked => _status == WorkspaceSessionStatus.blocked;

  /// Indica se la sessione è stata completata.
  bool get isCompleted => _status == WorkspaceSessionStatus.completed;

  /// Indica se la sessione è stata cancellata.
  bool get isCancelled => _status == WorkspaceSessionStatus.cancelled;

  /// Indica se il workspace contiene modifiche.
  bool get hasChanges => workspace.hasChanges;

  /// Numero di modifiche correnti.
  int get changeCount => workspace.changeCount;

  /// Diff corrente.
  GitWorkspaceDiff get diff => workspace.buildDiff();

  /// Motivo del blocco, se presente.
  String? get blockedReason => _blockedReason;

  /// Indica se l'applicazione delle modifiche è stata esplicitamente
  /// autorizzata.
  bool get isApplyApproved => _applyApproved;

  /// Inizializza il workspace leggendo il repository attraverso il gateway.
  ///
  /// Questa operazione è esclusivamente di lettura.
  Future<void> initialize({
    String? directory,
  }) async {
    _ensureCanInitialize();

    _status = WorkspaceSessionStatus.loading;

    try {
      await workspace.initialize(
        directory: directory ?? context.request.projectPath,
      );

      _status = WorkspaceSessionStatus.ready;
    } catch (error) {
      _blockedReason = 'Workspace initialization failed: $error';
      _status = WorkspaceSessionStatus.blocked;
      rethrow;
    }
  }

  /// Passa la sessione alla fase di analisi.
  void beginAnalysis() {
    _ensureOperational();

    _status = WorkspaceSessionStatus.working;
  }

  /// Passa la sessione alla fase di pianificazione.
  void beginPlanning() {
    _ensureOperational();

    _status = WorkspaceSessionStatus.working;
  }

  /// Passa la sessione alla fase di implementazione.
  ///
  /// Le modifiche devono essere effettuate sul [workspace] virtuale.
  void beginImplementation() {
    _ensureOperational();

    _status = WorkspaceSessionStatus.working;
  }

  /// Passa la sessione alla fase di review.
  ///
  /// Il Cantiere deve arrivare qui prima di poter applicare modifiche
  /// al repository reale.
  void beginReview() {
    _ensureOperational();

    _status = WorkspaceSessionStatus.review;
    _applyApproved = false;
  }

  /// Passa la sessione alla fase di validazione.
  void beginValidation() {
    _ensureOperational();

    _status = WorkspaceSessionStatus.validation;
    _applyApproved = false;
  }

  /// Registra l'approvazione esplicita delle modifiche.
  ///
  /// IMPORTANTE:
  /// questa operazione NON modifica ancora il repository.
  ///
  /// Serve come guardrail separato prima di [apply].
  void approveApply() {
    if (_status != WorkspaceSessionStatus.review &&
        _status != WorkspaceSessionStatus.validation) {
      throw StateError(
        'Changes can only be approved during review or validation.',
      );
    }

    if (!workspace.hasChanges) {
      throw StateError(
        'Cannot approve an empty workspace.',
      );
    }

    _applyApproved = true;
    _status = WorkspaceSessionStatus.approved;
  }

  /// Applica le modifiche al repository attraverso VirtualWorkspace.
  ///
  /// Questa è un'operazione MUTANTE.
  ///
  /// Non viene eseguita automaticamente durante:
  /// - initialize;
  /// - analysis;
  /// - planning;
  /// - implementation;
  /// - review;
  /// - validation.
  ///
  /// Richiede esplicitamente [approveApply].
  ///
  /// Non esegue commit o push.
  Future<void> apply() async {
    if (_status != WorkspaceSessionStatus.approved ||
        !_applyApproved) {
      throw StateError(
        'Workspace changes require explicit approval before apply().',
      );
    }

    if (!workspace.hasChanges) {
      throw StateError(
        'Cannot apply an empty workspace.',
      );
    }

    _status = WorkspaceSessionStatus.applying;

    try {
      await workspace.apply();

      _applyApproved = false;
      _status = WorkspaceSessionStatus.completed;
    } catch (error) {
      _blockedReason = 'Workspace apply failed: $error';
      _status = WorkspaceSessionStatus.blocked;
      rethrow;
    }
  }

  /// Blocca la sessione senza modificare il repository.
  void block(String reason) {
    final normalizedReason = reason.trim();

    _blockedReason = normalizedReason.isEmpty
        ? 'Workspace session blocked.'
        : normalizedReason;

    _applyApproved = false;
    _status = WorkspaceSessionStatus.blocked;
  }

  /// Cancella la sessione.
  ///
  /// Le modifiche virtuali rimangono solamente in memoria e non vengono
  /// applicate al repository.
  void cancel() {
    _applyApproved = false;
    _status = WorkspaceSessionStatus.cancelled;
  }

  /// Ripristina tutte le modifiche virtuali.
  ///
  /// Questa operazione NON modifica il repository remoto.
  void revertAll() {
    _ensureOperational();

    workspace.revertAll();
    _applyApproved = false;

    if (_status == WorkspaceSessionStatus.review ||
        _status == WorkspaceSessionStatus.validation ||
        _status == WorkspaceSessionStatus.approved) {
      _status = WorkspaceSessionStatus.working;
    }
  }

  /// Ripristina un singolo file allo stato originale.
  void revertFile(String path) {
    _ensureOperational();

    workspace.revert(path);
    _applyApproved = false;
  }

  /// Ricarica il workspace dal repository remoto.
  ///
  /// ATTENZIONE:
  /// le modifiche virtuali correnti vengono scartate.
  Future<void> reload({
    String? directory,
  }) async {
    _ensureOperational();

    _applyApproved = false;
    _status = WorkspaceSessionStatus.loading;

    try {
      await workspace.reload(
        directory: directory ?? context.request.projectPath,
      );

      _status = WorkspaceSessionStatus.ready;
    } catch (error) {
      _blockedReason = 'Workspace reload failed: $error';
      _status = WorkspaceSessionStatus.blocked;
      rethrow;
    }
  }

  /// Restituisce un riepilogo leggero utile alla UI o all'orchestratore.
  WorkspaceSessionSummary get summary {
    final currentDiff = workspace.buildDiff();

    return WorkspaceSessionSummary(
      requestId: context.request.id,
      title: context.request.title,
      status: _status,
      fileCount: workspace.fileCount,
      changeCount: currentDiff.files.length,
      blockedReason: _blockedReason,
      applyApproved: _applyApproved,
    );
  }

  void _ensureCanInitialize() {
    if (_status != WorkspaceSessionStatus.created) {
      throw StateError(
        'WorkspaceSession can only be initialized once.',
      );
    }
  }

  void _ensureOperational() {
    if (_status == WorkspaceSessionStatus.blocked) {
      throw StateError(
        'WorkspaceSession is blocked: $_blockedReason',
      );
    }

    if (_status == WorkspaceSessionStatus.cancelled) {
      throw StateError(
        'WorkspaceSession has been cancelled.',
      );
    }

    if (_status == WorkspaceSessionStatus.completed) {
      throw StateError(
        'WorkspaceSession has already been completed.',
      );
    }

    if (!workspace.isInitialized) {
      throw StateError(
        'WorkspaceSession must be initialized before this operation.',
      );
    }
  }
}

/// Snapshot leggero dello stato della sessione.
///
/// Non contiene il contenuto dei file e quindi può essere utilizzato
/// dalla UI, dai log o dall'orchestratore senza trasferire inutilmente
/// grandi quantità di dati.
final class WorkspaceSessionSummary {
  const WorkspaceSessionSummary({
    required this.requestId,
    required this.title,
    required this.status,
    required this.fileCount,
    required this.changeCount,
    required this.applyApproved,
    this.blockedReason,
  });

  final String requestId;
  final String title;
  final WorkspaceSessionStatus status;
  final int fileCount;
  final int changeCount;
  final bool applyApproved;
  final String? blockedReason;

  bool get hasChanges => changeCount > 0;

  bool get isBlocked =>
      status == WorkspaceSessionStatus.blocked;

  @override
  String toString() {
    return 'WorkspaceSessionSummary('
        'requestId=$requestId, '
        'status=${status.name}, '
        'fileCount=$fileCount, '
        'changeCount=$changeCount, '
        'applyApproved=$applyApproved'
        ')';
  }
}
