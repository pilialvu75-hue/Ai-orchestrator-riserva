import 'package:ai_orchestrator/core/agents/agent_message.dart';

/// A unit of work dispatched to one or more agents by the [TaskDispatcher].
class AgentTask {
  const AgentTask({
    required this.id,
    required this.instruction,
    this.targetAgentId,
    this.priority = TaskPriority.normal,
    this.metadata = const {},
  });

  /// Unique task identifier.
  final String id;

  /// Natural-language instruction describing the work to be done.
  final String instruction;

  /// Optional agent that should handle this task.
  ///
  /// When `null`, the [TaskDispatcher] selects the best available agent.
  final String? targetAgentId;

  /// Scheduling priority.
  final TaskPriority priority;

  /// Arbitrary key-value metadata (e.g. `{'context': '...', 'ttl': 30}`).
  final Map<String, dynamic> metadata;

  @override
  String toString() =>
      'AgentTask(id: $id, priority: ${priority.name}, '
      'target: ${targetAgentId ?? 'auto'})';
}

/// Scheduling priority levels for [AgentTask]s.
enum TaskPriority {
  /// Low-priority background work that can be deferred.
  low,

  /// Standard priority (default).
  normal,

  /// High-priority work that should pre-empt queued tasks.
  high,

  /// Critical tasks that must be executed immediately.
  critical,
}

/// Result produced when a dispatched [AgentTask] completes.
class TaskResult {
  const TaskResult({
    required this.taskId,
    required this.agentId,
    required this.output,
    this.success = true,
    this.error,
  });

  /// Identifier of the originating task.
  final String taskId;

  /// Identifier of the agent that executed the task.
  final String agentId;

  /// Human-readable output from the agent.
  final String output;

  /// Whether the task completed without errors.
  final bool success;

  /// Error description when [success] is `false`.
  final String? error;

  @override
  String toString() =>
      'TaskResult(taskId: $taskId, agentId: $agentId, success: $success)';
}

/// Abstract contract for dispatching tasks to the agent pool.
///
/// [TaskDispatcher] decouples callers from the details of which agent handles
/// a request.  It resolves the best available agent for a given task, queues
/// work when all agents are busy, and streams progress back to the caller.
///
/// Dependency rule:
///   core/agents/ defines [TaskDispatcher]
///   features/ / plugins/ provide concrete implementations
///
/// Planned implementations:
/// - `RoundRobinDispatcher` — simple load balancing for homogeneous agents.
/// - `CapabilityDispatcher` — routes tasks to agents with matching capability tags.
/// - `PriorityQueueDispatcher` — strict priority-queue scheduling.
abstract class TaskDispatcher {
  /// Dispatches [task] and returns its [TaskResult] when complete.
  Future<TaskResult> dispatch(AgentTask task);

  /// Dispatches [task] and returns a stream of intermediate [AgentMessage]s.
  ///
  /// The stream closes with the final [TaskResult] message when the task ends.
  Stream<AgentMessage> dispatchStreaming(AgentTask task);

  /// Registers an agent [agentId] as available for task assignment.
  void registerAgent(String agentId);

  /// Removes agent [agentId] from the dispatch pool.
  void deregisterAgent(String agentId);

  /// Returns `true` when at least one agent is available to accept new tasks.
  bool get hasAvailableAgent;

  // TODO(future): add cancelTask(String taskId) for cancellable dispatch.
  // TODO(future): add List<AgentTask> get pendingTasks to inspect the queue.
}
