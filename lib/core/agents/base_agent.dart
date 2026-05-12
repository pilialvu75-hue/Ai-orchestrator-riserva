import 'package:ai_orchestrator/core/agents/agent_lifecycle.dart';
import 'package:ai_orchestrator/core/agents/agent_message.dart';
import 'package:ai_orchestrator/core/agents/shared_context.dart';

/// Result of an [BaseAgent.executeTask] invocation.
class TaskExecutionResult {
  const TaskExecutionResult({
    required this.taskId,
    required this.agentId,
    required this.output,
    this.success = true,
    this.error,
  });

  final String taskId;
  final String agentId;
  final String output;
  final bool success;
  final String? error;

  @override
  String toString() =>
      'TaskExecutionResult(taskId: $taskId, agentId: $agentId, '
      'success: $success)';
}

/// Enhanced abstract contract for all autonomous AI agents.
///
/// [BaseAgent] extends the minimal [Agent] contract with a full lifecycle
/// (initialize → activate → suspend → shutdown) and inter-agent communication
/// primitives (communicate / executeTask).
///
/// All specialised agent types ([OrchestratorAgent], [ReasoningAgent],
/// [KnowledgeAgent], [ToolAgent], [RuntimeAgent]) extend [BaseAgent].
///
/// Dependency rule:
///   core/agents/ ← features/ and plugin agent implementations
///   core/agents/ → core/tools/, core/ai/, core/memory/  (within-core allowed)
///   core/agents/ → native/                              (forbidden)
abstract class BaseAgent {
  /// Unique, stable agent identifier (e.g. `'reasoning_agent'`).
  String get id;

  /// Human-readable agent name shown in the UI.
  String get name;

  /// One-sentence description of this agent's specialisation.
  String get description;

  /// Current lifecycle state of the agent.
  AgentLifecycleState get lifecycleState;

  /// Convenience accessor: `true` when [lifecycleState] is [AgentLifecycleState.active].
  bool get isRunning => lifecycleState == AgentLifecycleState.active;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Sets up internal resources (DB handles, tool bindings, subscriptions).
  ///
  /// Must be called before [activate].  Transitions state:
  /// `created → initialising → idle`.
  Future<void> initialize();

  /// Marks the agent as ready to accept tasks.
  ///
  /// Transitions state: `idle → active` or `suspended → active`.
  Future<void> activate();

  /// Temporarily pauses the agent without releasing resources.
  ///
  /// Any in-progress task completes; new tasks are rejected until [activate]
  /// is called again.  Transitions state: `active → suspended`.
  Future<void> suspend();

  /// Releases all resources and puts the agent into a terminal state.
  ///
  /// After [shutdown] the agent instance must not be reused.
  /// Transitions state: `* → shutdown`.
  Future<void> shutdown();

  // ── Communication ─────────────────────────────────────────────────────────

  /// Sends or receives an [AgentMessage] from another agent.
  ///
  /// Implementations should route the message through the [MessageBus]
  /// rather than calling other agents directly to preserve decoupling.
  Future<void> communicate(AgentMessage message);

  // ── Task execution ────────────────────────────────────────────────────────

  /// Executes [instruction] within the given [context].
  ///
  /// Returns a [TaskExecutionResult] describing success or failure.
  ///
  /// The [taskId] is provided by the caller (e.g. [TaskDispatcher]) so that
  /// results can be correlated back to the originating request.
  Future<TaskExecutionResult> executeTask(
    String taskId,
    String instruction,
    SharedContext context,
  );

  // TODO(future): add Stream<AgentEvent> observe() for streaming progress.
  // TODO(future): add cancel(String taskId) to interrupt running tasks.
  // TODO(future): add List<Tool> get availableTools to expose tool bindings.
}
