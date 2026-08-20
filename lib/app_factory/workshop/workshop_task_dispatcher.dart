import 'workshop_task_contract.dart';
import 'workshop_task_execution_guard.dart';
import 'workshop_task_executor.dart';

/// Dispatcher del Cantiere.
///
/// Collega:
///
///   Task
///     ↓
///   Execution Guard
///     ↓
///   Dispatcher
///     ↓
///   Executor
///
/// Il Dispatcher NON:
///
/// - pianifica task;
/// - sceglie la risorsa;
/// - modifica il repository;
/// - aumenta il budget;
/// - cambia modalità;
/// - sostituisce il Guard.
///
/// La scelta della risorsa deve essere già stata effettuata
/// dall'allocator e verificata dal Guard.
final class WorkshopTaskDispatcher {
  WorkshopTaskDispatcher({
    Iterable<WorkshopTaskExecutor> executors =
        const <WorkshopTaskExecutor>[],
  }) {
    registerExecutors(executors);
  }

  final List<WorkshopTaskExecutor> _executors =
      <WorkshopTaskExecutor>[];

  /// Executor registrati.
  List<WorkshopTaskExecutor> get executors =>
      List<WorkshopTaskExecutor>.unmodifiable(
        _executors,
      );

  /// Numero di executor disponibili.
  int get executorCount => _executors.length;

  /// Registra un executor.
  ///
  /// La coppia resource/provider identifica l'implementazione.
  /// Un executor più recente sostituisce quello precedente.
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

    return before != _executors.length;
  }

  /// Restituisce l'executor compatibile con la decisione del Guard.
  ///
  /// Prima cerca una corrispondenza esatta resource + provider.
  /// Se non esiste, può utilizzare un executor generico della stessa
  /// risorsa, cioè con providerId == null.
  WorkshopTaskExecutor? findExecutor({
    required WorkshopTaskExecutionGuardDecision guardDecision,
  }) {
    if (!guardDecision.isAllowed) {
      return null;
    }

    final resource = guardDecision.resource;

    if (resource == null) {
      return null;
    }

    final providerId = guardDecision.providerId;

    if (providerId != null) {
      for (final executor in _executors) {
        if (executor.resource == resource &&
            executor.providerId == providerId &&
            executor.isAvailable) {
          return executor;
        }
      }
    }

    for (final executor in _executors) {
      if (executor.resource == resource &&
          executor.providerId == null &&
          executor.isAvailable) {
        return executor;
      }
    }

    return null;
  }

  /// Esegue una task dopo la decisione del Guard.
  ///
  /// Una decisione bloccata viene rispettata sempre.
  ///
  /// Il Dispatcher non effettua fallback automatici:
  /// se l'executor richiesto non è disponibile, la task fallisce
  /// in modo esplicito invece di cambiare provider o modalità.
  Future<WorkshopTaskExecutionResult> dispatch({
    required WorkshopTaskContract task,
    required WorkshopTaskExecutionGuardDecision guardDecision,
    required WorkshopTaskExecutionContext context,
    WorkshopTaskExecutionProgressCallback? onProgress,
  }) async {
    if (!guardDecision.isAllowed) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status:
            guardDecision.blockReason ==
                    WorkshopTaskExecutionBlockReason
                        .approvalRequired
                ? WorkshopTaskStatus.waitingApproval
                : WorkshopTaskStatus.failed,
        message:
            'Task execution blocked by the Workshop Execution Guard: '
            '${guardDecision.message}',
      );
    }

    final executor = findExecutor(
      guardDecision: guardDecision,
    );

    if (executor == null) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message:
            'No available executor matches the authorized resource.',
        metadata: <String, dynamic>{
          'resource': guardDecision.resource?.name,
          'providerId': guardDecision.providerId,
        },
      );
    }

    try {
      final result = await executor.execute(
        task: task,
        guardDecision: guardDecision,
        context: context,
        onProgress: onProgress,
      );

      return _normalizeResult(
        task: task,
        result: result,
      );
    } catch (error) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message: 'Executor threw an unexpected error.',
        metadata: <String, dynamic>{
          'executorId': executor.executorId,
          'resource': executor.resource.name,
          'providerId': executor.providerId,
          'error': error.toString(),
        },
      );
    }
  }

  /// Verifica che il risultato appartenga realmente alla task
  /// che era stata inviata.
  ///
  /// Non modifica il risultato dell'executor se è valido.
  WorkshopTaskExecutionResult _normalizeResult({
    required WorkshopTaskContract task,
    required WorkshopTaskExecutionResult result,
  }) {
    if (result.taskId == task.id) {
      return result;
    }

    return WorkshopTaskExecutionResult(
      taskId: task.id,
      status: WorkshopTaskStatus.failed,
      message:
          'Executor returned a result for a different task.',
      metadata: <String, dynamic>{
        'expectedTaskId': task.id,
        'returnedTaskId': result.taskId,
      },
    );
  }

  /// Restituisce tutti gli executor disponibili per una risorsa.
  List<WorkshopTaskExecutor> executorsForResource(
    WorkshopTaskResource resource,
  ) {
    return List<WorkshopTaskExecutor>.unmodifiable(
      _executors.where(
        (executor) =>
            executor.resource == resource &&
            executor.isAvailable,
      ),
    );
  }

  /// Verifica se esiste almeno un executor disponibile.
  bool hasAvailableExecutor(
    WorkshopTaskResource resource, {
    String? providerId,
  }) {
    return _executors.any(
      (executor) =>
          executor.resource == resource &&
          executor.isAvailable &&
          (providerId == null ||
              executor.providerId == providerId ||
              executor.providerId == null),
    );
  }

  /// Restituisce una descrizione diagnostica degli executor.
  ///
  /// Utile per log, debug e schermata Developer Mode.
  List<Map<String, dynamic>> diagnostics() {
    return List<Map<String, dynamic>>.unmodifiable(
      _executors.map(
        (executor) => <String, dynamic>{
          'executorId': executor.executorId,
          'resource': executor.resource.name,
          'providerId': executor.providerId,
          'isAvailable': executor.isAvailable,
        },
      ),
    );
  }
}
