import 'package:ai_orchestrator/core/agents/base_agent.dart';
import 'package:ai_orchestrator/core/agents/shared_context.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';

/// Abstract contract for the tool-execution agent role.
///
/// The [ToolAgent] is the **tool-invocation specialist** of the multi-agent
/// system.  Its responsibilities are:
///
/// - Maintain a registry of available [Tool] instances.
/// - Select the most appropriate tool for a given instruction.
/// - Invoke tools with correct parameters and handle their results.
/// - Translate raw [ToolResult]s into structured [ToolAgentResult]s.
///
/// The [ToolAgent] is the **only** agent that should directly call [Tool.execute].
/// All other agents that require tool capabilities must route their requests
/// through the [ToolAgent] via the [MessageBus].
///
/// Concrete implementations will bind the agent to a specific tool set
/// (file I/O, web search, code runner, etc.).  No tool logic is implemented
/// here — this is a pure architectural contract.
///
/// Dependency rule:
///   core/agents/ ← features/ tool-agent implementations
///   core/agents/ → core/tools/ (allowed — same layer)
///   core/agents/ → native/     (forbidden — use core/runtime/ instead)
abstract class ToolAgent extends BaseAgent {
  /// The set of tools registered with this agent.
  List<Tool> get availableTools;

  /// Invokes the best available tool for [instruction] within [context] and
  /// returns a structured [ToolAgentResult].
  ///
  /// The agent is responsible for:
  /// 1. Parsing [instruction] to determine which tool to call.
  /// 2. Extracting the correct parameters from [instruction] / [context].
  /// 3. Calling [Tool.execute] and wrapping the output.
  ///
  /// If no suitable tool is found, [ToolAgentResult.success] is `false` and
  /// [ToolAgentResult.error] explains why.
  Future<ToolAgentResult> invokeTool(
    String instruction,
    SharedContext context,
  );

  /// Returns the [Tool] registered under [toolId], or `null` if not found.
  Tool? findTool(String toolId);

  /// Registers [tool] so it is available for invocation.
  ///
  /// If a tool with the same [Tool.id] is already registered, it is replaced.
  void registerTool(Tool tool);

  /// Removes the tool identified by [toolId] from the registry.
  ///
  /// No-op if the tool is not registered.
  void unregisterTool(String toolId);

  // TODO(future): add Stream<ToolInvocationEvent> observeInvocations() for audit logs.
  // TODO(future): add List<Tool> recommendTools(String instruction) for LLM-assisted routing.
}

/// Result produced by [ToolAgent.invokeTool].
class ToolAgentResult {
  const ToolAgentResult({
    required this.agentId,
    required this.toolId,
    required this.output,
    this.success = true,
    this.error,
  });

  /// Identifier of the [ToolAgent] that performed the invocation.
  final String agentId;

  /// Identifier of the [Tool] that was invoked, or an empty string if no tool
  /// was selected.
  final String toolId;

  /// The tool's textual output (file content, search result, code output, etc.).
  final String output;

  /// Whether the tool invocation completed without errors.
  final bool success;

  /// Error description when [success] is `false`.
  final String? error;

  @override
  String toString() =>
      'ToolAgentResult(agentId: $agentId, toolId: $toolId, success: $success)';
}
