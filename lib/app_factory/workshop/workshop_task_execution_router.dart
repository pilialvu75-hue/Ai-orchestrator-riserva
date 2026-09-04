import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_resource_allocator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resource_registry.dart';

/// Contesto minimo passato all'esecuzione di una task.
///
/// Il Router non contiene la logica specifica del provider.
/// Trasporta soltanto le informazioni necessarie all'executor.
final class WorkshopTaskExecutionContext {
  const WorkshopTaskExecutionContext({
    required this.task,
    required this.allocation,
    this.projectId,
    this.sessionId = 'workshop',
    this.networkAvailable = true,
    this.stagingRoot,
  });

  final WorkshopTaskContract task;
  final WorkshopResourceAllocation allocation;
  final String? projectId;
  final String sessionId;
  final bool networkAvailable;

  /// Directory virtuale/staging dove l'executor può lavorare.
  ///
  /// Il Router non scrive mai direttamente in questa directory.
  final String? stagingRoot;
}

/// Risultato normalizzato dell'esecuzione di una task.
///
/// Il risultato non implica automaticamente un merge o un'applicazione
/// delle modifiche al repository reale.
final class WorkshopTaskExecutionResult {
  const WorkshopTaskExecutionResult({
    required this.taskId,
    required this.resource,
    required this.success,
    required this.message,
    this.providerId,
    this.output,
    this.artifactPath,
    this.error,
    this.requiresApproval = false,
    this.checkpointId,
  });

  final String taskId;
  final WorkshopTaskResource resource;
  final String? providerId;
  final bool success;
  final String message;
  final String? output;
  final String? artifactPath;
  final String? error;

  /// True quando il lavoro è terminato ma non può essere applicato
  /// senza una decisione esplicita dell'utente.
  final bool requiresApproval;

  final String? checkpointId;

  bool get isFailure => !success;

  bool get isCompleted => success && !requiresApproval;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'taskId': taskId,
      'resource': resource.name,
      'providerId': providerId,
      'success': success,
      'message': message,
      'output': output,
      'artifactPath': artifactPath,
      'error': error,
      'requiresApproval': requiresApproval,
      'checkpointId': checkpointId,
    };
  }
}

/// Executor concreto di una risorsa.
///
/// Ogni provider/infrastruttura potrà implementare questa interfaccia
/// senza modificare il Router.
///
/// Esempi futuri:
///
/// - LocalTaskExecutor
/// - OpenAiTaskExecutor
/// - GeminiTaskExecutor
/// - ClaudeTaskExecutor
/// - GrokTaskExecutor
/// - GithubAgentTaskExecutor
/// - GithubActionsTaskExecutor
/// - HybridAiTaskExecutor
abstract interface class WorkshopTaskExecutor {
  /// Identificatore della risorsa gestita dall'executor.
  WorkshopTaskResource get resource;

  /// Identificatore opzionale del provider concreto.
  ///
  /// Se null, l'executor può gestire qualsiasi provider della
  /// categoria [resource].
  String? get providerId;

  /// True quando l'executor può gestire la task.
  bool canExecute(WorkshopTaskExecutionContext context);

  /// Esegue la task.
  ///
  /// L'executor è responsabile del proprio confine operativo.
  ///
  /// Il Router non presume che l'executor modifichi il repository.
  /// La policy di staging/approval deve essere rispettata dall'executor.
  Future<WorkshopTaskExecutionResult> execute(
    WorkshopTaskExecutionContext context,
  );
}

/// Router delle esecuzioni del Cantiere.
///
/// Responsabilità:
///
/// - chiedere al Resource Allocator quale risorsa usare;
/// - trovare l'executor corrispondente;
/// - passare il contesto all'executor;
/// - normalizzare il risultato;
/// - impedire esecuzioni quando non esiste una risorsa sicura.
///
/// NON:
///
/// - pianifica il progetto;
/// - sostituisce WorkshopEngine;
/// - decide autonomamente quale provider preferire;
/// - chiama direttamente OpenAI/Gemini/Claude/Grok;
/// - chiama direttamente GitHub Agent;
/// - avvia direttamente GitHub Actions;
/// - modifica direttamente il repository.
///
/// In questo modo il Router rimane un componente di infrastruttura.
final class WorkshopTaskExecutionRouter {
  WorkshopTaskExecutionRouter({
    WorkshopResourceRegistry? registry,
    WorkshopTaskResourceAllocator? allocator,
    Iterable<WorkshopTaskExecutor> executors =
        const <WorkshopTaskExecutor>[],
  })  : _registry = registry ?? WorkshopResourceRegistry(),
        _allocator =
            allocator ?? const WorkshopTaskResourceAllocator() {
    registerExecutors(executors);
  }

  final WorkshopResourceRegistry _registry;

  final WorkshopTaskResourceAllocator _allocator;

  final List<WorkshopTaskExecutor> _executors =
      <WorkshopTaskExecutor>[];

  /// Numero di executor registrati.
  int get executorCount => _executors.length;

  /// Executor attualmente registrati.
  List<WorkshopTaskExecutor> get executors {
    return List<WorkshopTaskExecutor>.unmodifiable(
      _executors,
    );
  }

  /// Registra un executor.
  ///
  /// Un executor con la stessa risorsa/provider viene sostituito.
  void registerExecutor(
    WorkshopTaskExecutor executor,
  ) {
    _executors.removeWhere(
      (existing) =>
          existing.resource == executor.resource &&
          existing.providerId == executor.providerId,
    );

    _executors.add(executor);
  }

  /// Registra più executor.
  void registerExecutors(
    Iterable<WorkshopTaskExecutor> executors,
  ) {
    for (final executor in executors) {
      registerExecutor(executor);
    }
  }

  /// Rimuove un executor.
  bool removeExecutor({
    required WorkshopTaskResource resource,
    String? providerId,
  }) {
    final before = _executors.length;

    _executors.removeWhere(
      (executor) =>
          executor.resource == resource &&
          executor.providerId == providerId,
    );

    return _executors.length != before;
  }

  /// Esegue una task utilizzando la risorsa selezionata
  /// dal Resource Allocator.
  ///
  /// Se nessuna risorsa è disponibile, la task non viene eseguita.
  ///
  /// Il Router non effettua fallback impliciti dopo che
  /// l'allocatore ha selezionato una risorsa.
  Future<WorkshopTaskExecutionResult> execute({
    required WorkshopTaskContract task,
    String? projectId,
    String sessionId = 'workshop',
    bool networkAvailable = true,
    String? stagingRoot,
  }) async {
    if (sessionId.trim().isEmpty) {
      return _failure(
        task: task,
        resource: task.preferredResource,
        message: 'Execution session is invalid.',
        error: 'sessionId cannot be empty.',
      );
    }

    final allocation = _allocator.allocate(
      task: task,
      resources: _registry.snapshot(),
      networkAvailable: networkAvailable,
    );

    if (allocation == null) {
      return _failure(
        task: task,
        resource: task.preferredResource,
        message:
            'No safe execution resource is currently available.',
        error:
            'Resource allocation failed for task ${task.id}.',
      );
    }

    if (allocation.taskId != task.id) {
      return _failure(
        task: task,
        resource: allocation.resource,
        providerId: allocation.providerId,
        message:
            'Execution allocation does not match the task.',
        error:
            'Allocation taskId ${allocation.taskId} '
            'does not match ${task.id}.',
      );
    }

    if (allocation.requiresNetwork &&
        !networkAvailable) {
      return _failure(
        task: task,
        resource: allocation.resource,
        providerId: allocation.providerId,
        message:
            'Execution requires network access.',
        error:
            'Network is unavailable for the allocated resource.',
      );
    }

    final context = WorkshopTaskExecutionContext(
      task: task,
      allocation: allocation,
      projectId: projectId,
      sessionId: sessionId,
      networkAvailable: networkAvailable,
      stagingRoot: stagingRoot,
    );

    final executor = _findExecutor(
      allocation: allocation,
      context: context,
    );

    if (executor == null) {
      return _failure(
        task: task,
        resource: allocation.resource,
        providerId: allocation.providerId,
        message:
            'A resource was allocated, but no executor '
            'is registered.',
        error:
            'Missing executor for ${allocation.resource.name}'
            '${allocation.providerId == null ? '' : ':${allocation.providerId}'}.',
      );
    }

    try {
      final result = await executor.execute(context);

      // L'executor deve restituire il risultato della stessa task.
      // Il Router non corregge silenziosamente risultati incoerenti.
      if (result.taskId != task.id) {
        return _failure(
          task: task,
          resource: allocation.resource,
          providerId: allocation.providerId,
          message:
              'Executor returned an invalid task result.',
          error:
              'Result taskId ${result.taskId} '
              'does not match ${task.id}.',
        );
      }

      // La risorsa effettivamente usata deve corrispondere
      // alla risorsa autorizzata dall'allocator.
      if (result.resource != allocation.resource) {
        return _failure(
          task: task,
          resource: allocation.resource,
          providerId: allocation.providerId,
          message:
              'Executor returned an invalid resource result.',
          error:
              'Result resource ${result.resource.name} '
              'does not match ${allocation.resource.name}.',
        );
      }

      return result;
    } catch (error, stackTrace) {
      return _failure(
        task: task,
        resource: allocation.resource,
        providerId: allocation.providerId,
        message: 'Task executor failed.',
        error: '$error\n$stackTrace',
      );
    }
  }

  WorkshopTaskExecutionResult _failure({
    required WorkshopTaskContract task,
    required WorkshopTaskResource resource,
    required String message,
    required String error,
    String? providerId,
  }) {
    return WorkshopTaskExecutionResult(
      taskId: task.id,
      resource: resource,
      providerId: providerId,
      success: false,
      message: message,
      error: error,
    );
  }

  /// Determina quale executor deve ricevere la task.
  ///
  /// Prima viene cercata una corrispondenza esatta
  /// resource + provider.
  ///
  /// Successivamente viene cercato un executor generico
  /// della stessa categoria.
  WorkshopTaskExecutor? _findExecutor({
    required WorkshopResourceAllocation allocation,
    required WorkshopTaskExecutionContext context,
  }) {
    WorkshopTaskExecutor? generic;

    for (final executor in _executors) {
      if (executor.resource != allocation.resource) {
        continue;
      }

      if (executor.providerId == allocation.providerId &&
          executor.canExecute(context)) {
        return executor;
      }

      if (executor.providerId == null &&
          executor.canExecute(context)) {
        generic ??= executor;
      }
    }

    return generic;
  }

  /// Verifica se esiste almeno un executor per una risorsa.
  bool hasExecutor({
    required WorkshopTaskResource resource,
    String? providerId,
  }) {
    return _executors.any(
      (executor) =>
          executor.resource == resource &&
          (executor.providerId == providerId ||
              executor.providerId == null),
    );
  }

  /// Restituisce gli executor compatibili con una task.
  List<WorkshopTaskExecutor> compatibleExecutors(
    WorkshopTaskContract task, {
    bool networkAvailable = true,
    String? projectId,
    String sessionId = 'workshop',
    String? stagingRoot,
  }) {
    final result = <WorkshopTaskExecutor>[];

    if (sessionId.trim().isEmpty) {
      return const <WorkshopTaskExecutor>[];
    }

    for (final executor in _executors) {
      final allocation = WorkshopResourceAllocation(
        taskId: task.id,
        resource: executor.resource,
        providerId: executor.providerId,
        reason: 'Compatibility inspection.',
        fallbacks: const <WorkshopTaskResource>[],
        estimatedCredits: 0,
        estimatedLatencyMs: 0,
        requiresNetwork:
            executor.resource !=
                WorkshopTaskResource.local,
      );

      if (allocation.requiresNetwork &&
          !networkAvailable) {
        continue;
      }

      final context = WorkshopTaskExecutionContext(
        task: task,
        allocation: allocation,
        projectId: projectId,
        sessionId: sessionId,
        networkAvailable: networkAvailable,
        stagingRoot: stagingRoot,
      );

      if (executor.canExecute(context)) {
        result.add(executor);
      }
    }

    return List<WorkshopTaskExecutor>.unmodifiable(
      result,
    );
  }

  /// Aggiorna il registry utilizzato dal Router.
  ///
  /// Utile quando lo stato delle risorse cambia:
  ///
  /// - rete disponibile/non disponibile;
  /// - crediti cambiati;
  /// - toolchain locale installata;
  /// - GitHub Agent disponibile;
  /// - GitHub Actions disponibile;
  /// - provider cloud temporaneamente degradato.
  void registerResource(
    WorkshopResourceSnapshot snapshot,
  ) {
    _registry.register(snapshot);
  }

  /// Aggiorna più risorse.
  void registerResources(
    Iterable<WorkshopResourceSnapshot> snapshots,
  ) {
    _registry.registerAll(snapshots);
  }

  /// Accesso in sola lettura al Registry.
  WorkshopResourceRegistry get registry => _registry;

  /// Accesso alla policy di allocazione.
  WorkshopResourceAllocationPolicy get allocationPolicy =>
      _allocator.policy;
}
