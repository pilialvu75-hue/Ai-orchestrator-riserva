import 'package:ai_orchestrator/core/agents/base_agent.dart';
import 'package:ai_orchestrator/core/agents/shared_context.dart';
import 'package:ai_orchestrator/core/runtime/runtime_provider.dart';

/// Abstract contract for the runtime agent role.
///
/// The [RuntimeAgent] bridges the agent system with the platform execution
/// layer.  Its responsibilities are:
///
/// - Select the appropriate [RuntimeProvider] for the current environment.
/// - Forward execution requests from the agent pool to the runtime.
/// - Monitor runtime health and report availability back to the orchestrator.
/// - Translate raw [RuntimeProvider] outputs into structured [RuntimeAgentResult]s.
///
/// The [RuntimeAgent] is the **only** agent that is allowed to hold a
/// reference to a [RuntimeProvider].  All other agents that need to run
/// platform commands must send a message to the [RuntimeAgent] through the
/// [MessageBus].
///
/// Dependency rule:
///   core/agents/ ← features/ runtime-agent implementations
///   core/agents/ → core/runtime/ (allowed — same layer)
///   core/agents/ → native/       (forbidden — use RuntimeProvider instead)
abstract class RuntimeAgent extends BaseAgent {
  /// The [RuntimeProvider] this agent is currently backed by.
  RuntimeProvider get runtimeProvider;

  /// Executes [command] through the underlying [RuntimeProvider] and returns
  /// a [RuntimeAgentResult].
  Future<RuntimeAgentResult> runCommand(
    String command,
    SharedContext context,
  );

  /// Returns `true` when the underlying [RuntimeProvider.isSupported] is true
  /// and the agent is in the [AgentLifecycleState.active] state.
  bool get isRuntimeAvailable;

  /// Human-readable label for the runtime environment this agent manages
  /// (e.g. `'Android Local'`, `'Cloud Sandbox'`, `'Hybrid'`).
  String get runtimeLabel;

  // TODO(future): add switchRuntime(RuntimeProvider) for hot-swapping backends.
  // TODO(future): add Stream<RuntimeHealthEvent> monitorHealth() for liveness.
}

/// Result produced by [RuntimeAgent.runCommand].
class RuntimeAgentResult {
  const RuntimeAgentResult({
    required this.agentId,
    required this.command,
    required this.output,
    this.success = true,
    this.error,
  });

  /// Identifier of the [RuntimeAgent] that executed the command.
  final String agentId;

  /// The raw command that was passed to the [RuntimeProvider].
  final String command;

  /// Human-readable output from the runtime.
  final String output;

  /// Whether the command completed without errors.
  final bool success;

  /// Error description when [success] is `false`.
  final String? error;

  @override
  String toString() =>
      'RuntimeAgentResult(agentId: $agentId, success: $success)';
}
