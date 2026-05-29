import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/inference/prompt_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';

class RollingContextResult {
  const RollingContextResult({
    required this.contextLines,
    required this.contextTurns,
    required this.recalledLines,
    required this.trimmedLines,
    required this.overflowDetected,
    required this.totalChars,
  });

  final List<String> contextLines;
  final List<PromptTurn> contextTurns;
  final List<String> recalledLines;
  final int trimmedLines;
  final bool overflowDetected;
  final int totalChars;
}

class _ContextEntry {
  const _ContextEntry({
    required this.line,
    this.turn,
    this.isRecalled = false,
  });

  final String line;
  final PromptTurn? turn;
  final bool isRecalled;
}

class RollingContextBuilder {
  const RollingContextBuilder({
    required MemoryWindowManager windowManager,
  }) : _windowManager = windowManager;

  final MemoryWindowManager _windowManager;

  RollingContextResult build({
    required List<ChatMessage> messages,
    required String userPrompt,
    String? systemPrompt,
    String? excludedMessageId,
    List<String> recalledContext = const <String>[],
  }) {
    final seen = <String>{};
    final entries = <_ContextEntry>[];

    for (final recalled in recalledContext) {
      final normalized = recalled.trim();
      if (normalized.isEmpty) continue;
      if (!seen.add(normalized)) continue;
      entries.add(_ContextEntry(line: normalized, isRecalled: true));
    }

    for (final message in messages) {
      if (excludedMessageId != null && message.id == excludedMessageId) continue;
      final normalized = '${message.role}: ${message.content}'.trim();
      if (normalized.isEmpty) continue;
      if (!seen.add(normalized)) continue;
      entries.add(
        _ContextEntry(
          line: normalized,
          turn: _toPromptTurn(message),
        ),
      );
    }

    final result = _windowManager.trimToWindow(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      contextLines: entries.map((entry) => entry.line).toList(growable: false),
    );
    final entryByLine = <String, _ContextEntry>{
      for (final entry in entries) entry.line: entry,
    };
    final contextTurns = <PromptTurn>[];
    final recalledLines = <String>[];
    for (final line in result.contextLines) {
      final entry = entryByLine[line];
      if (entry == null) continue;
      if (entry.turn != null) {
        contextTurns.add(entry.turn!);
      } else if (entry.isRecalled) {
        recalledLines.add(line);
      }
    }

    return RollingContextResult(
      contextLines: result.contextLines,
      contextTurns: contextTurns,
      recalledLines: recalledLines,
      trimmedLines: result.trimmedLines,
      overflowDetected: result.overflowDetected,
      totalChars: result.totalChars,
    );
  }

  PromptTurn? _toPromptTurn(ChatMessage message) {
    final normalizedRole = message.role.trim().toLowerCase();
    if (normalizedRole != 'user' &&
        normalizedRole != 'assistant' &&
        normalizedRole != 'system') {
      return null;
    }
    final normalizedContent = message.content.trim();
    if (normalizedContent.isEmpty) return null;
    return PromptTurn(
      role: normalizedRole,
      content: normalizedContent,
    );
  }
}
