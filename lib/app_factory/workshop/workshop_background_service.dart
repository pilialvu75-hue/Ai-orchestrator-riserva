import 'dart:async';

import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';

export 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
//import 'workshop_project_plan.dart';

/// Evento prodotto dall'infrastruttura Background del Cantiere.
///
/// The persistable checkpoint contract lives in workshop_checkpoint_store.dart,
/// while delivery semantics remain owned by the native/background service.
final class WorkshopBackgroundEvent {
  const WorkshopBackgroundEvent({
    required this.checkpoint,
    required this.type,
  });

  final WorkshopBackgroundCheckpoint checkpoint;
  final WorkshopBackgroundEventType type;
}

enum WorkshopBackgroundEventType {
  started,
  checkpoint,
  paused,
  resumed,
  waitingApproval,
  completed,
  failed,
  cancelled,
}

/// Astrazione per le notifiche.
///
/// Non dipendiamo ancora da un plugin specifico.
/// In futuro questa interfaccia verrà collegata alle notifiche Android/iOS.
abstract interface class WorkshopNotificationSink {
  Future<void> notifyRunning(
    WorkshopBackgroundCheckpoint checkpoint,
  );

  Future<void> notifyWaitingApproval(
    WorkshopBackgroundCheckpoint checkpoint,
  );

  Future<void> notifyCompleted(
    WorkshopBackgroundCheckpoint checkpoint,
  );

  Future<void> notifyFailed(
    WorkshopBackgroundCheckpoint checkpoint,
  );
}

/// Sink silenzioso utilizzato finché il layer native notification non è
/// collegato.
final class NoopWorkshopNotificationSink
    implements WorkshopNotificationSink {
  const NoopWorkshopNotificationSink();

  @override
  Future<void> notifyRunning(
    WorkshopBackgroundCheckpoint checkpoint,
  ) async {}

  @override
  Future<void> notifyWaitingApproval(
    WorkshopBackgroundCheckpoint checkpoint,
  ) async {}

  @override
  Future<void> notifyCompleted(
    WorkshopBackgroundCheckpoint checkpoint,
  ) async {}

  @override
  Future<void> notifyFailed(
    WorkshopBackgroundCheckpoint checkpoint,
  ) async {}
}

/// Infrastructure Orchestrator del Cantiere.
///
/// Responsabilità:
///
/// - eseguire il lavoro fuori dalla UI;
/// - mantenere lo stato del job;
/// - creare checkpoint;
/// - permettere pause/riprese;
/// - notificare gli stati importanti;
/// - preparare il recupero dopo una terminazione.
///
/// NON è un secondo WorkshopEngine.
///
/// WorkshopEngine decide COSA fare.
/// WorkshopBackgroundService decide COME mantenere operativo il lavoro.
///
/// Il servizio non applica mai automaticamente modifiche al repository.
final class WorkshopBackgroundService {
  WorkshopBackgroundService({
    required WorkshopEngine engine,
    WorkshopCheckpointStore? checkpointStore,
    WorkshopNotificationSink? notificationSink,
  })  : _engine = engine,
        _checkpointStore =
            checkpointStore ?? InMemoryWorkshopCheckpointStore(),
        _notificationSink =
            notificationSink ?? const NoopWorkshopNotificationSink();

  final WorkshopEngine _engine;
  final WorkshopCheckpointStore _checkpointStore;
  final WorkshopNotificationSink _notificationSink;

  final Map<String, WorkshopBackgroundCheckpoint> _activeJobs =
      <String, WorkshopBackgroundCheckpoint>{};

  final StreamController<WorkshopBackgroundEvent> _events =
      StreamController<WorkshopBackgroundEvent>.broadcast();

  bool _disposed = false;

  Stream<WorkshopBackgroundEvent> get events =>
      _events.stream;

  List<WorkshopBackgroundCheckpoint> get activeJobs =>
      List.unmodifiable(_activeJobs.values);

  bool get isDisposed => _disposed;

  /// Avvia un lavoro.
  ///
  /// Questa API è volutamente asincrona e indipendente dalla UI.
  /// L'adapter Android potrà richiamarla da un worker in background.
  Future<WorkshopBackgroundCheckpoint> start(
    WorkshopRequest request,
  ) async {
    _ensureAvailable();

    final jobId = _jobIdFor(request.id);

    final existing = await _checkpointStore.load(jobId);

    if (existing != null &&
        !existing.isTerminal &&
        existing.status != WorkshopBackgroundStatus.cancelled) {
      _activeJobs[jobId] = existing;
      return existing;
    }

    final checkpoint = WorkshopBackgroundCheckpoint(
      jobId: jobId,
      requestId: request.id,
      status: WorkshopBackgroundStatus.running,
      updatedAt: DateTime.now(),
      message: 'Workshop job started.',
    );

    await _saveAndEmit(
      checkpoint,
      WorkshopBackgroundEventType.started,
    );

    unawaited(
      _runJob(
        request,
        jobId,
      ),
    );

    return checkpoint;
  }

  /// Riprende un job esistente dopo una pausa o un'interruzione.
  Future<WorkshopBackgroundCheckpoint?> resume(
    String jobId,
  ) async {
    _ensureAvailable();

    final checkpoint =
        await _checkpointStore.load(jobId);

    if (checkpoint == null) {
      return null;
    }

    if (checkpoint.isTerminal) {
      return checkpoint;
    }

    final resumed = WorkshopBackgroundCheckpoint(
      jobId: checkpoint.jobId,
      requestId: checkpoint.requestId,
      status: WorkshopBackgroundStatus.running,
      updatedAt: DateTime.now(),
      projectId: checkpoint.projectId,
      taskId: checkpoint.taskId,
      completedTasks: checkpoint.completedTasks,
      totalTasks: checkpoint.totalTasks,
      message: 'Workshop job resumed.',
      error: checkpoint.error,
    );

    await _saveAndEmit(
      resumed,
      WorkshopBackgroundEventType.resumed,
    );

    return resumed;
  }

  /// Mette in pausa un job.
  ///
  /// La pausa è cooperativa: il worker reale dovrà arrivare a un
  /// checkpoint sicuro prima di fermarsi.
  Future<WorkshopBackgroundCheckpoint?> pause(
    String jobId,
  ) async {
    _ensureAvailable();

    final checkpoint =
        await _checkpointStore.load(jobId);

    if (checkpoint == null) {
      return null;
    }

    if (checkpoint.isTerminal) {
      return checkpoint;
    }

    final paused = WorkshopBackgroundCheckpoint(
      jobId: checkpoint.jobId,
      requestId: checkpoint.requestId,
      status: WorkshopBackgroundStatus.paused,
      updatedAt: DateTime.now(),
      projectId: checkpoint.projectId,
      taskId: checkpoint.taskId,
      completedTasks: checkpoint.completedTasks,
      totalTasks: checkpoint.totalTasks,
      message: 'Workshop job paused.',
      error: checkpoint.error,
    );

    await _saveAndEmit(
      paused,
      WorkshopBackgroundEventType.paused,
    );

    return paused;
  }

  /// Indica che il lavoro ha raggiunto il gate di approvazione.
  ///
  /// Questo è il punto in cui verrà inviata la notifica:
  ///
  /// "Cantiere pronto per la revisione".
  Future<WorkshopBackgroundCheckpoint?> requestApproval(
    String jobId, {
    String? projectId,
    String? taskId,
    int completedTasks = 0,
    int totalTasks = 0,
    String? message,
  }) async {
    _ensureAvailable();

    final current =
        await _checkpointStore.load(jobId);

    if (current == null) {
      return null;
    }

    final checkpoint = WorkshopBackgroundCheckpoint(
      jobId: current.jobId,
      requestId: current.requestId,
      status: WorkshopBackgroundStatus.waitingApproval,
      updatedAt: DateTime.now(),
      projectId: projectId ?? current.projectId,
      taskId: taskId ?? current.taskId,
      completedTasks: completedTasks,
      totalTasks: totalTasks,
      message:
          message ?? 'Workshop project is ready for review.',
      error: current.error,
    );

    await _saveAndEmit(
      checkpoint,
      WorkshopBackgroundEventType.waitingApproval,
    );

    await _notificationSink.notifyWaitingApproval(
      checkpoint,
    );

    return checkpoint;
  }

  /// Registra il completamento definitivo del lavoro.
  ///
  /// Non significa che il repository reale sia stato modificato.
  /// Il gate Apply resta separato.
  Future<WorkshopBackgroundCheckpoint?> complete(
    String jobId, {
    String? projectId,
    String? message,
    int completedTasks = 0,
    int totalTasks = 0,
  }) async {
    _ensureAvailable();

    final current =
        await _checkpointStore.load(jobId);

    if (current == null) {
      return null;
    }

    final checkpoint = WorkshopBackgroundCheckpoint(
      jobId: current.jobId,
      requestId: current.requestId,
      status: WorkshopBackgroundStatus.completed,
      updatedAt: DateTime.now(),
      projectId: projectId ?? current.projectId,
      taskId: current.taskId,
      completedTasks: completedTasks,
      totalTasks: totalTasks,
      message:
          message ?? 'Workshop project completed.',
      error: current.error,
    );

    await _saveAndEmit(
      checkpoint,
      WorkshopBackgroundEventType.completed,
    );

    await _notificationSink.notifyCompleted(
      checkpoint,
    );

    return checkpoint;
  }

  /// Registra un errore senza perdere il checkpoint.
  Future<WorkshopBackgroundCheckpoint?> fail(
    String jobId,
    String error, {
    String? message,
  }) async {
    _ensureAvailable();

    final current =
        await _checkpointStore.load(jobId);

    if (current == null) {
      return null;
    }

    final checkpoint = WorkshopBackgroundCheckpoint(
      jobId: current.jobId,
      requestId: current.requestId,
      status: WorkshopBackgroundStatus.failed,
      updatedAt: DateTime.now(),
      projectId: current.projectId,
      taskId: current.taskId,
      completedTasks: current.completedTasks,
      totalTasks: current.totalTasks,
      message:
          message ?? 'Workshop project failed.',
      error: error,
    );

    await _saveAndEmit(
      checkpoint,
      WorkshopBackgroundEventType.failed,
    );

    await _notificationSink.notifyFailed(
      checkpoint,
    );

    return checkpoint;
  }

  /// Recupera tutti i checkpoint persistiti.
  Future<List<WorkshopBackgroundCheckpoint>> recover() async {
    _ensureAvailable();

    final checkpoints =
        await _checkpointStore.loadAll();

    for (final checkpoint in checkpoints) {
      if (!checkpoint.isTerminal) {
        _activeJobs[checkpoint.jobId] = checkpoint;
      }
    }

    return checkpoints;
  }

  /// Cancella un job.
  Future<void> cancel(
    String jobId,
  ) async {
    _ensureAvailable();

    final current =
        await _checkpointStore.load(jobId);

    if (current == null) {
      return;
    }

    final checkpoint = WorkshopBackgroundCheckpoint(
      jobId: current.jobId,
      requestId: current.requestId,
      status: WorkshopBackgroundStatus.cancelled,
      updatedAt: DateTime.now(),
      projectId: current.projectId,
      taskId: current.taskId,
      completedTasks: current.completedTasks,
      totalTasks: current.totalTasks,
      message: 'Workshop job cancelled.',
      error: current.error,
    );

    await _saveAndEmit(
      checkpoint,
      WorkshopBackgroundEventType.cancelled,
    );

    _activeJobs.remove(jobId);
  }

  Future<void> _runJob(
    WorkshopRequest request,
    String jobId,
  ) async {
    try {
      final result = await _engine.execute(request);

      if (result.success) {
        await requestApproval(
          jobId,
          message:
              'Workshop work is ready for review.',
        );
      } else {
        await fail(
          jobId,
          result.errors.isEmpty
              ? 'Workshop execution failed.'
              : result.errors.join('\n'),
          message: result.message,
        );
      }
    } catch (error) {
      await fail(
        jobId,
        error.toString(),
      );
    }
  }

  Future<void> _saveAndEmit(
    WorkshopBackgroundCheckpoint checkpoint,
    WorkshopBackgroundEventType type,
  ) async {
    await _checkpointStore.save(checkpoint);

    _activeJobs[checkpoint.jobId] = checkpoint;

    if (!_events.isClosed) {
      _events.add(
        WorkshopBackgroundEvent(
          checkpoint: checkpoint,
          type: type,
        ),
      );
    }

    if (checkpoint.status ==
        WorkshopBackgroundStatus.running) {
      await _notificationSink.notifyRunning(
        checkpoint,
      );
    }
  }

  String _jobIdFor(String requestId) =>
      'workshop-job:$requestId';

  void _ensureAvailable() {
    if (_disposed) {
      throw StateError(
        'WorkshopBackgroundService has been disposed.',
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;

    await _events.close();
  }
}
