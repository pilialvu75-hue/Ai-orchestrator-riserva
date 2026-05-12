/// Base contract for all autonomous AI agents.
///
/// Agents are specialised units that independently plan and execute
/// multi-step tasks using tools, memory, and AI providers.
///
/// Concrete implementations go in feature modules or plugins and must
/// interact with the environment exclusively through the contracts
/// defined in `core/` (tools, memory, AI providers).
///
/// Dependency rule:
///   core/agents/ ← features/ agent implementations
///   core/agents/ → core/tools/, core/ai/   (within-core allowed)
///   core/agents/ → native/                 (forbidden)
abstract class Agent {
  /// Unique, stable agent identifier (e.g. `'coding_agent'`).
  String get id;

  /// Human-readable agent name shown in the UI.
  String get name;

  /// Whether the agent is currently executing a task.
  bool get isRunning;

  /// Executes a task from a natural-language [instruction].
  ///
  /// Returns an [AgentResult] describing success or failure.
  Future<AgentResult> run(String instruction);

  // TODO(future): add Stream<AgentEvent> observe() for streaming progress.
  // TODO(future): add cancel() to interrupt a running task gracefully.
  // TODO(future): add List<Tool> get availableTools to expose tool bindings.
}

/// The result of an [Agent] task execution.
class AgentResult {
  const AgentResult({
    required this.agentId,
    required this.output,
    this.success = true,
    this.error,
  });

  /// Identifier of the agent that produced this result.
  final String agentId;

  /// The agent's textual output (answer, code snippet, summary, etc.).
  final String output;

  /// Whether the task completed successfully.
  final bool success;

  /// Error description when [success] is `false`.
  final String? error;

  @override
  String toString() =>
      'AgentResult(agentId: $agentId, success: $success, output: $output)';
}
