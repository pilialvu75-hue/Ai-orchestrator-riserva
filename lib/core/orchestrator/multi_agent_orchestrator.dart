import 'package:ai_orchestrator/core/agents/agent_lifecycle.dart';
import 'package:ai_orchestrator/core/agents/base_agent.dart';
import 'package:ai_orchestrator/core/agents/message_bus.dart';
import 'package:ai_orchestrator/core/agents/orchestrator_agent.dart';
import 'package:ai_orchestrator/core/agents/shared_context.dart';
import 'package:ai_orchestrator/core/agents/task_dispatcher.dart';
import 'package:ai_orchestrator/core/orchestrator/orchestration_strategy.dart';

/// Placeholder coordinator that will evolve into the multi-agent runtime hub.
///
/// [MultiAgentOrchestrator] is the future top-level entry point for every
/// multi-agent session.  In the current milestone it is a lightweight
/// placeholder that defines the public surface area without implementing real
/// coordination logic.
///
/// Planned responsibilities (future milestones):
/// 1. Maintain a registry of all active [BaseAgent] instances.
/// 2. Manage agent lifecycle across the session (initialize → shutdown).
/// 3. Route goals through an [OrchestrationStrategy].
/// 4. Own the session-scoped [SharedContext] and [MessageBus].
/// 5. Expose a unified API for higher-level features and UI.
///
/// Dependency rule:
///   core/orchestrator/ defines [MultiAgentOrchestrator]
///   features/ / injection_container.dart wire concrete implementations
///   core/orchestrator/ → core/agents/ (within-core allowed)
///   core/orchestrator/ → native/      (forbidden)
class MultiAgentOrchestrator {
  MultiAgentOrchestrator({
    required MessageBus messageBus,
    required TaskDispatcher dispatcher,
    required SharedContext context,
    OrchestrationStrategy? strategy,
  })  : _messageBus = messageBus,
        _dispatcher = dispatcher,
        _context = context,
        _strategy = strategy;

  final MessageBus _messageBus;
  final TaskDispatcher _dispatcher;
  final SharedContext _context;
  final OrchestrationStrategy? _strategy;

  final Map<String, BaseAgent> _agents = {};

  // ── Agent registry ────────────────────────────────────────────────────────

  /// Registers [agent] and makes it available for task dispatch.
  ///
  /// [BaseAgent.initialize] is called automatically if the agent is in the
  /// [AgentLifecycleState.created] state.
  Future<void> addAgent(BaseAgent agent) async {
    if (agent.lifecycleState == AgentLifecycleState.created) {
      await agent.initialize();
    }
    _agents[agent.id] = agent;
    _dispatcher.registerAgent(agent.id);
  }

  /// Removes [agentId] from the registry and calls [BaseAgent.shutdown].
  Future<void> removeAgent(String agentId) async {
    final agent = _agents.remove(agentId);
    if (agent != null) {
      _dispatcher.deregisterAgent(agentId);
      await agent.shutdown();
    }
  }

  /// Returns all registered agents.
  List<BaseAgent> get agents => List.unmodifiable(_agents.values);

  // ── Orchestration ─────────────────────────────────────────────────────────

  /// Submits [goal] for orchestration using the configured [OrchestrationStrategy].
  ///
  /// Returns an [OrchestrationResult] when the run finishes.
  ///
  /// **Placeholder behaviour**: if no strategy is set, returns a not-implemented
  /// result immediately so existing functionality is unaffected.
  Future<OrchestrationResult> run(String goal) async {
    if (_strategy == null || _agents.isEmpty) {
      // Placeholder: strategy or agents not yet wired up.
      return OrchestrationResult(
        runId: 'placeholder',
        goal: goal,
        taskResults: const [],
        success: false,
        error: 'Cannot execute goal: orchestration strategy or agents are not '
            'configured (strategy: ${_strategy?.id ?? 'none'}, '
            'agents: ${_agents.length}).',
      );
    }

    return _strategy.execute(
      goal,
      agents,
      _context,
      _dispatcher,
    );
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Shuts down all registered agents and disposes shared resources.
  Future<void> shutdown() async {
    for (final agent in _agents.values) {
      await agent.shutdown();
    }
    _agents.clear();
    await _messageBus.dispose();
  }

  // TODO(future): add broadcast(AgentMessage) for session-wide messages.
  // TODO(future): add monitorHealth() stream for agent liveness checks.
  // TODO(future): add pauseAll() / resumeAll() for session-level suspend.
}
