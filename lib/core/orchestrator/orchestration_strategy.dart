import 'package:ai_orchestrator/core/agents/base_agent.dart';
import 'package:ai_orchestrator/core/agents/orchestrator_agent.dart';
import 'package:ai_orchestrator/core/agents/shared_context.dart';
import 'package:ai_orchestrator/core/agents/task_dispatcher.dart';

/// Abstract contract for orchestration strategies.
///
/// An [OrchestrationStrategy] encapsulates the **how** of coordinating a pool
/// of agents to achieve a goal.  Swapping strategies changes the coordination
/// algorithm without touching the agents themselves.
///
/// Built-in strategy identifiers (to be implemented in feature modules):
/// - `'sequential'`   — run sub-tasks one after another in order.
/// - `'parallel'`     — run all independent sub-tasks concurrently.
/// - `'hierarchical'` — delegate sub-goals to sub-orchestrators recursively.
/// - `'reactive'`     — re-plan based on intermediate results (ReAct loop).
///
/// Dependency rule:
///   core/orchestrator/ ← features/ strategy implementations
///   core/orchestrator/ → core/agents/ (within-core allowed)
abstract class OrchestrationStrategy {
  /// Stable identifier for this strategy (e.g. `'sequential'`).
  String get id;

  /// Human-readable name for display purposes.
  String get name;

  /// Executes the strategy for [goal] using the provided [agents] and
  /// [context], dispatching work through [dispatcher].
  ///
  /// Returns an [OrchestrationResult] when the strategy run is complete.
  Future<OrchestrationResult> execute(
    String goal,
    List<BaseAgent> agents,
    SharedContext context,
    TaskDispatcher dispatcher,
  );

  // TODO(future): add validate(List<BaseAgent>) → bool to check preconditions.
  // TODO(future): add Stream<OrchestrationProgress> executeStreaming(...) for live updates.
}
