import 'package:ai_orchestrator/core/agents/base_agent.dart';
import 'package:ai_orchestrator/core/agents/shared_context.dart';
import 'package:ai_orchestrator/core/agents/task_dispatcher.dart';

/// Abstract contract for the orchestrator agent role.
///
/// The [OrchestratorAgent] is the **strategic coordinator** of a multi-agent
/// session.  Its responsibilities are:
///
/// - Decompose a high-level goal into sub-tasks.
/// - Select the right specialist agents for each sub-task.
/// - Dispatch sub-tasks through the [TaskDispatcher].
/// - Aggregate results and maintain overall progress in [SharedContext].
/// - Handle failures and retry or re-route failed sub-tasks.
///
/// There should be at most one [OrchestratorAgent] per orchestration session.
/// It does not perform domain work itself; it delegates to specialists.
///
/// Dependency rule:
///   core/agents/ ← features/ orchestrator implementations
///   core/agents/ → core/ only (no native/ or features/ imports here)
abstract class OrchestratorAgent extends BaseAgent {
  /// Starts a new orchestration run for the given high-level [goal].
  ///
  /// Returns when all sub-tasks have completed or the run is aborted.
  Future<OrchestrationResult> orchestrate(
    String goal,
    SharedContext context,
  );

  /// Registers a specialist [agent] that this orchestrator may delegate to.
  void registerSpecialist(BaseAgent agent);

  /// Removes a previously registered specialist by [agentId].
  void deregisterSpecialist(String agentId);

  /// Returns the identifiers of all currently registered specialists.
  List<String> get specialistIds;

  // TODO(future): add planGoal(String goal) → List<AgentTask> for plan preview.
  // TODO(future): add cancelOrchestration(String runId) for graceful abort.
}

/// Summary result produced when an [OrchestratorAgent.orchestrate] run ends.
class OrchestrationResult {
  const OrchestrationResult({
    required this.runId,
    required this.goal,
    required this.taskResults,
    this.success = true,
    this.summary,
    this.error,
  });

  /// Unique identifier of this orchestration run.
  final String runId;

  /// The original high-level goal that was orchestrated.
  final String goal;

  /// Individual task results from each delegated sub-task.
  final List<TaskResult> taskResults;

  /// Whether all sub-tasks completed successfully.
  final bool success;

  /// Optional human-readable summary of the run's outcome.
  final String? summary;

  /// Error description when [success] is `false`.
  final String? error;

  @override
  String toString() =>
      'OrchestrationResult(runId: $runId, success: $success, '
      'tasks: ${taskResults.length})';
}
