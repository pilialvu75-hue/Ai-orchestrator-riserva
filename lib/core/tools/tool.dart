/// Base contract for all tools available to agents and workflows.
///
/// Tools expose discrete, reusable capabilities (file I/O, web search,
/// code execution, etc.) that agents call as atomic operations.
///
/// Concrete tool implementations live in feature modules or plugins and
/// must interact with the system exclusively through `core/` contracts.
///
/// Dependency rule:
///   core/tools/ ← features/ tool implementations
///   core/tools/ → core/ only
///   core/tools/ → native/   (forbidden — use core/runtime/ instead)
abstract class Tool {
  /// Unique, stable tool identifier (e.g. `'file_reader'`, `'web_search'`).
  String get id;

  /// Human-readable name displayed in agent reasoning traces.
  String get name;

  /// One-sentence description of what this tool does.
  ///
  /// This description is forwarded to the language model so it can decide
  /// when to invoke the tool.
  String get description;

  /// Executes the tool with JSON-serialisable [params] and returns a result.
  ///
  /// The shape of [params] is tool-specific and should be documented by
  /// each concrete implementation.
  Future<ToolResult> execute(Map<String, dynamic> params);

  // TODO(future): add Map<String, dynamic> get schema to expose a JSON Schema
  //               for [params] so the LLM can generate valid invocations.
}

/// The result of a [Tool] execution.
class ToolResult {
  const ToolResult({
    required this.toolId,
    required this.output,
    this.success = true,
    this.error,
  });

  /// Identifier of the tool that produced this result.
  final String toolId;

  /// The tool's textual output (file contents, search results, etc.).
  final String output;

  /// Whether the tool executed successfully.
  final bool success;

  /// Error description when [success] is `false`.
  final String? error;

  @override
  String toString() =>
      'ToolResult(toolId: $toolId, success: $success, output: $output)';
}
