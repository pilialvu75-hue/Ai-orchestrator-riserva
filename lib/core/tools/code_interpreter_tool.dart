import 'package:ai_orchestrator/core/tools/tool.dart';

/// A set of regex patterns that indicate potentially destructive operations.
///
/// The [CodeInterpreterTool] uses these to flag generated code that may modify
/// files, directories, or system state outside the repository.  Any match
/// causes [ToolResult.requiresConfirmation] to be noted in the output so the
/// UI can present a confirmation dialog before the user runs the code.
const List<String> _destructivePatterns = [
  r'rm\s+-rf?',         // Shell: rm -rf
  r'shutil\.rmtree',    // Python: shutil.rmtree
  r'os\.remove',        // Python: os.remove
  r'os\.unlink',        // Python: os.unlink
  r'File\.delete',      // Dart: File.delete()
  r'Directory\.delete', // Dart: Directory.delete()
  r'format\s+[a-zA-Z]:', // Shell: format drive
  r'\bdrop\s+table\b',  // SQL: DROP TABLE
  r'\btruncate\s+table\b', // SQL: TRUNCATE TABLE
];

/// Tool that generates, analyses, and safely classifies code snippets.
///
/// Inspired by the TaskWeaver Code Interpreter, [CodeInterpreterTool] adapts
/// the concept to the offline-first Flutter environment where arbitrary code
/// cannot be sandboxed and executed on-device.  Instead the tool:
///
/// 1. **Accepts** a code snippet (or a description to fill a template).
/// 2. **Analyses** the snippet for potentially destructive operations.
/// 3. **Returns** a [ToolResult] whose [ToolResult.output] includes:
///    - The code snippet itself.
///    - A `[SAFE]` or `[REQUIRES CONFIRMATION]` safety annotation.
///    - A brief safety explanation when confirmation is required.
///
/// Consumers (e.g. [CodingAssistantAgentImpl]) must display the annotation to
/// the user and request explicit confirmation before executing code flagged as
/// `[REQUIRES CONFIRMATION]`.
///
/// **params shape:**
/// ```dart
/// {
///   'code': '<dart or python code snippet>',     // required
///   'language': 'dart' | 'python' | 'shell',    // optional, default 'dart'
///   'description': '<what this code does>',      // optional hint
/// }
/// ```
///
/// Dependency rule:
///   core/tools/ ← features/ implementations (this class lives in core/tools/)
///   core/tools/ → core/ only (no native/ or features/ imports)
class CodeInterpreterTool implements Tool {
  const CodeInterpreterTool();

  @override
  String get id => 'code_interpreter';

  @override
  String get name => 'Code Interpreter';

  @override
  String get description =>
      'Analyses a code snippet for safety and returns an annotated version '
      'ready for review. Flags any destructive operations that require user '
      'confirmation before execution.';

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    final code = params['code'] as String? ?? '';
    final language = params['language'] as String? ?? 'dart';
    final codeDescription = params['description'] as String? ?? '';

    if (code.trim().isEmpty) {
      return ToolResult(
        toolId: id,
        output: '',
        success: false,
        error: 'No code snippet provided. Supply a "code" key in params.',
      );
    }

    final isDestructive = _containsDestructivePattern(code);
    final annotation = isDestructive
        ? '[REQUIRES CONFIRMATION] This code contains potentially destructive '
            'operations (file deletion, directory removal, or database DROP). '
            'User confirmation is required before execution.'
        : '[SAFE] No destructive operations detected. This code can be run '
            'within the repository sandbox autonomously.';

    final header = StringBuffer()
      ..writeln('// Language: $language')
      ..writeln('// Description: ${codeDescription.isNotEmpty ? codeDescription : "N/A"}')
      ..writeln('// Safety: ${isDestructive ? "REQUIRES CONFIRMATION" : "SAFE"}')
      ..writeln();

    final output = '${header}${code}\n\n$annotation';

    return ToolResult(
      toolId: id,
      output: output,
      success: true,
    );
  }

  // ── Private ────────────────────────────────────────────────────────────────

  bool _containsDestructivePattern(String code) {
    for (final pattern in _destructivePatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(code)) {
        return true;
      }
    }
    return false;
  }
}
