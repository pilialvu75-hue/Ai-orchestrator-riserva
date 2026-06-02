import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

class MemoryWindowResult {
  const MemoryWindowResult({
    required this.contextTurns,
    required this.trimmedLines,
    required this.overflowDetected,
    required this.totalChars,
  });

  final List<ChatTurn> contextTurns;
  final int trimmedLines;
  final bool overflowDetected;
  final int totalChars;
}

class MemoryWindowManager {
  const MemoryWindowManager({
    this.maxContextLines = 24,
    this.maxTotalChars = 2200,
    this.minContextChars = 320,
  });

  final int maxContextLines;
  final int maxTotalChars;
  final int minContextChars;

  MemoryWindowResult trimToWindow({
    required String? systemPrompt,
    required String userPrompt,
    required List<ChatTurn> contextTurns,
  }) {
    final bounded = contextTurns.length <= maxContextLines
        ? List<ChatTurn>.from(contextTurns)
        : contextTurns.sublist(contextTurns.length - maxContextLines);
    var trimmedLines = contextTurns.length - bounded.length;
    var overflowDetected = false;

    final systemChars = systemPrompt?.trim().length ?? 0;
    final userChars = userPrompt.trim().length;
    final dynamicBudget =
        (maxTotalChars - systemChars - userChars).clamp(minContextChars, maxTotalChars);

    var runningChars = _estimateChars(bounded);
    while (bounded.isNotEmpty && runningChars > dynamicBudget) {
      overflowDetected = true;
      bounded.removeAt(0);
      trimmedLines++;
      runningChars = _estimateChars(bounded);
    }

    return MemoryWindowResult(
      contextTurns: List<ChatTurn>.unmodifiable(bounded),
      trimmedLines: trimmedLines,
      overflowDetected: overflowDetected,
      totalChars: runningChars + systemChars + userChars,
    );
  }

  int _estimateChars(List<ChatTurn> turns) {
    var chars = 0;
    for (final turn in turns) {
      chars += turn.content.trim().length + turn.role.name.length + 2;
    }
    return chars;
  }
}
