/// Persistable Cantiere job states shared by native and browser adapters.
enum WorkshopBackgroundStatus {
  idle,
  running,
  paused,
  waitingApproval,
  completed,
  failed,
  cancelled,
}

/// Durable, provider-neutral Cantiere checkpoint.
///
/// This contract deliberately has no Flutter, filesystem, process, database,
/// runtime-provider or WorkshopEngine dependency, so storage adapters can be
/// reused by Web without pulling native execution into the browser graph.
final class WorkshopBackgroundCheckpoint {
  const WorkshopBackgroundCheckpoint({
    required this.jobId,
    required this.requestId,
    required this.status,
    required this.updatedAt,
    this.projectId,
    this.taskId,
    this.completedTasks = 0,
    this.totalTasks = 0,
    this.message,
    this.error,
  });

  final String jobId;
  final String requestId;
  final WorkshopBackgroundStatus status;
  final DateTime updatedAt;
  final String? projectId;
  final String? taskId;
  final int completedTasks;
  final int totalTasks;
  final String? message;
  final String? error;

  double get progress {
    if (totalTasks <= 0) return 0;
    return (completedTasks / totalTasks).clamp(0, 1).toDouble();
  }

  bool get requiresUserApproval =>
      status == WorkshopBackgroundStatus.waitingApproval;

  bool get isTerminal =>
      status == WorkshopBackgroundStatus.completed ||
      status == WorkshopBackgroundStatus.failed ||
      status == WorkshopBackgroundStatus.cancelled;
}

/// Canonical Cantiere checkpoint persistence boundary.
abstract interface class WorkshopCheckpointStore {
  Future<void> save(WorkshopBackgroundCheckpoint checkpoint);

  Future<WorkshopBackgroundCheckpoint?> load(String jobId);

  Future<List<WorkshopBackgroundCheckpoint>> loadAll();

  Future<void> remove(String jobId);
}

/// Bounded in-process implementation used by tests and non-durable callers.
final class InMemoryWorkshopCheckpointStore
    implements WorkshopCheckpointStore {
  final Map<String, WorkshopBackgroundCheckpoint> _items =
      <String, WorkshopBackgroundCheckpoint>{};

  @override
  Future<void> save(WorkshopBackgroundCheckpoint checkpoint) async {
    _items[checkpoint.jobId] = checkpoint;
  }

  @override
  Future<WorkshopBackgroundCheckpoint?> load(String jobId) async =>
      _items[jobId];

  @override
  Future<List<WorkshopBackgroundCheckpoint>> loadAll() async =>
      List<WorkshopBackgroundCheckpoint>.unmodifiable(_items.values);

  @override
  Future<void> remove(String jobId) async {
    _items.remove(jobId);
  }
}
