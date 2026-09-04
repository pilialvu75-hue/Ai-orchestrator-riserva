import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_execution_guard.dart';

/// Contesto controllato fornito all'executor.
///
/// L'executor non decide quale risorsa utilizzare:
/// riceve già la task e la decisione autorizzativa del Guard.
///
/// I percorsi sono stringhe per mantenere il contratto indipendente
/// dalla piattaforma e dall'implementazione concreta della toolchain.
final class WorkshopTaskExecutionContext {
  const WorkshopTaskExecutionContext({
    this.stagingRoot,
    this.workingDirectory,
    this.networkAvailable = true,
    this.metadata = const <String, dynamic>{},
  });

  /// Directory virtuale/staging nella quale l'executor può lavorare.
  ///
  /// Non rappresenta automaticamente il repository reale.
  final String? stagingRoot;

  /// Directory di lavoro assegnata all'executor.
  final String? workingDirectory;

  /// Stato di rete osservato al momento dell'esecuzione.
  final bool networkAvailable;

  /// Informazioni infrastrutturali aggiuntive.
  final Map<String, dynamic> metadata;
}

/// Informazione di avanzamento prodotta da un executor.
///
/// Non contiene log arbitrari obbligatori: il chiamante può decidere
/// successivamente come visualizzare o persistere questi dati.
final class WorkshopTaskExecutionProgress {
  const WorkshopTaskExecutionProgress({
    required this.taskId,
    required this.phase,
    this.message,
    this.completedSteps = 0,
    this.totalSteps,
    this.progress,
    this.checkpoint,
    this.metadata = const <String, dynamic>{},
  });

  final String taskId;

  /// Fase corrente dell'esecuzione.
  final String phase;

  /// Messaggio leggibile dall'utente o dal Workshop.
  final String? message;

  final int completedSteps;

  final int? totalSteps;

  /// Valore compreso normalmente tra 0 e 1.
  ///
  /// Può essere null quando l'executor non è in grado
  /// di determinare una percentuale attendibile.
  final double? progress;

  /// Checkpoint prodotto durante l'esecuzione.
  final WorkshopTaskCheckpoint? checkpoint;

  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'taskId': taskId,
      'phase': phase,
      'message': message,
      'completedSteps': completedSteps,
      'totalSteps': totalSteps,
      'progress': progress,
      'checkpoint': checkpoint?.toJson(),
      'metadata': metadata,
    };
  }
}

/// Callback utilizzato dall'executor per comunicare avanzamento.
///
/// Il callback deve rimanere leggero:
/// la persistenza dei checkpoint appartiene al livello infrastrutturale
/// del WorkshopBackgroundService.
typedef WorkshopTaskExecutionProgressCallback = void Function(
  WorkshopTaskExecutionProgress progress,
);

/// Risultato finale di un'esecuzione.
///
/// Il risultato descrive ciò che è successo, ma non applica automaticamente
/// nulla al repository reale.
///
/// Le modifiche devono rimanere nello staging fino al successivo
/// processo di revisione/approvazione.
final class WorkshopTaskExecutionResult {
  const WorkshopTaskExecutionResult({
    required this.taskId,
    required this.status,
    this.message,
    this.checkpoint,
    this.changedFiles = const <String>[],
    this.artifacts = const <String>[],
    this.metadata = const <String, dynamic>{},
  });

  final String taskId;

  final WorkshopTaskStatus status;

  final String? message;

  /// Ultimo checkpoint prodotto dall'executor.
  final WorkshopTaskCheckpoint? checkpoint;

  /// File modificati nello staging.
  ///
  /// Non implica che siano stati applicati al repository reale.
  final List<String> changedFiles;

  /// Identificativi o percorsi degli artifact prodotti.
  final List<String> artifacts;

  final Map<String, dynamic> metadata;

  bool get isCompleted =>
      status == WorkshopTaskStatus.completed;

  bool get isFailed =>
      status == WorkshopTaskStatus.failed;

  bool get isCancelled =>
      status == WorkshopTaskStatus.cancelled;

  bool get requiresApproval =>
      status == WorkshopTaskStatus.waitingApproval;

  bool get succeeded => isCompleted && !isFailed;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'taskId': taskId,
      'status': status.name,
      'message': message,
      'checkpoint': checkpoint?.toJson(),
      'changedFiles': changedFiles,
      'artifacts': artifacts,
      'metadata': metadata,
    };
  }
}

/// Contratto astratto di esecuzione di una task del Cantiere.
///
/// L'executor:
///
/// - NON pianifica;
/// - NON sceglie la risorsa;
/// - NON decide se una task è autorizzata;
/// - NON bypassa l'Execution Guard;
/// - NON applica automaticamente modifiche al repository reale.
///
/// Riceve:
///
/// 1. una task già definita dal Task Planner;
/// 2. una decisione del Resource Allocator/Execution Guard;
/// 3. un contesto di staging;
///
/// e produce un risultato verificabile.
///
/// Le implementazioni concrete potranno essere:
///
/// - LocalTaskExecutor;
/// - GithubAgentTaskExecutor;
/// - GithubActionsTaskExecutor;
/// - HybridAiTaskExecutor;
/// - CloudTaskExecutor.
///
/// Questo permette di mantenere lo stesso contratto quando
/// cambieranno piattaforma, provider AI o toolchain.
abstract interface class WorkshopTaskExecutor {
  /// Identificativo stabile dell'executor.
  String get executorId;

  /// Risorsa che questo executor rappresenta.
  ///
  /// L'executor non può scegliere autonomamente una risorsa diversa.
  WorkshopTaskResource get resource;

  /// Provider opzionale utilizzato dall'executor.
  ///
  /// Esempi:
  /// - openai;
  /// - gemini;
  /// - claude;
  /// - grok;
  /// - llama_cpp;
  /// - github_agent;
  /// - github_actions.
  String? get providerId;

  /// Indica se l'executor è attualmente disponibile.
  ///
  /// Questo valore descrive lo stato osservato.
  /// La decisione finale di esecuzione appartiene al Guard.
  bool get isAvailable;

  /// Esegue una task già autorizzata.
  ///
  /// IMPORTANTE:
  ///
  /// L'implementazione deve rifiutare una decisione bloccata.
  ///
  /// L'executor non deve:
  ///
  /// - cambiare modalità;
  /// - scegliere un altro provider;
  /// - aumentare il budget;
  /// - bypassare l'approvazione;
  /// - scrivere direttamente nel repository reale.
  Future<WorkshopTaskExecutionResult> execute({
    required WorkshopTaskContract task,
    required WorkshopTaskExecutionGuardDecision guardDecision,
    required WorkshopTaskExecutionContext context,
    WorkshopTaskExecutionProgressCallback? onProgress,
  });
}

/// Executor nullo utilizzabile come fallback sicuro.
///
/// Non esegue alcun lavoro.
///
/// È utile per:
/// - inizializzazione del Workshop;
/// - test;
/// - modalità dry-run;
/// - quando nessun executor reale è ancora disponibile.
///
/// In questo modo il sistema non deve usare null sparsi nella pipeline.
final class WorkshopNoOpTaskExecutor
    implements WorkshopTaskExecutor {
  const WorkshopNoOpTaskExecutor({
    this.executorId = 'noop',
    this.resource = WorkshopTaskResource.local,
    this.providerId,
  });

  @override
  final String executorId;

  @override
  final WorkshopTaskResource resource;

  @override
  final String? providerId;

  @override
  bool get isAvailable => true;

  @override
  Future<WorkshopTaskExecutionResult> execute({
    required WorkshopTaskContract task,
    required WorkshopTaskExecutionGuardDecision guardDecision,
    required WorkshopTaskExecutionContext context,
    WorkshopTaskExecutionProgressCallback? onProgress,
  }) async {
    if (!guardDecision.isAllowed) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message:
            'Execution rejected by the Workshop Execution Guard: '
            '${guardDecision.message}',
      );
    }

    onProgress?.call(
      WorkshopTaskExecutionProgress(
        taskId: task.id,
        phase: 'noop',
        message: 'No-op executor: task was not executed.',
      ),
    );

    return WorkshopTaskExecutionResult(
      taskId: task.id,
      status: WorkshopTaskStatus.completed,
      message:
          'No-op executor completed without performing changes.',
    );
  }
}
