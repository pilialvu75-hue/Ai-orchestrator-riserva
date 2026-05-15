import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';

class RollingContextResult {
  const RollingContextResult({
    required this.contextLines,
    required this.trimmedLines,
    required this.overflowDetected,
    required this.totalChars,
  });

  final List<String> contextLines;
  final int trimmedLines;
  final bool overflowDetected;
  final int totalChars;
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
    final lines = <String>[];

    for (final recalled in recalledContext) {
      final normalized = recalled.trim();
      if (normalized.isEmpty) continue;
      if (!seen.add(normalized)) continue;
      lines.add(normalized);
    }

    for (final message in messages) {
      if (excludedMessageId != null && message.id == excludedMessageId) continue;
      final normalized = '${message.role}: ${message.content}'.trim();
      if (normalized.isEmpty) continue;
      if (!seen.add(normalized)) continue;
      lines.add(normalized);
    }

    final result = _windowManager.trimToWindow(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      contextLines: lines,
    );

    return RollingContextResult(
      contextLines: result.contextLines,
      trimmedLines: result.trimmedLines,
      overflowDetected: result.overflowDetected,
      totalChars: result.totalChars,
    );
  }
}

