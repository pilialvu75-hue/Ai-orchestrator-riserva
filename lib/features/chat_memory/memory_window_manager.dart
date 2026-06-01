class MemoryWindowResult {
  const MemoryWindowResult({
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
    required List<String> contextLines,
  }) {
    final bounded = contextLines.length <= maxContextLines
        ? List<String>.from(contextLines)
        : contextLines.sublist(contextLines.length - maxContextLines);
    var trimmedLines = contextLines.length - bounded.length;
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
      contextLines: List<String>.unmodifiable(bounded),
      trimmedLines: trimmedLines,
      overflowDetected: overflowDetected,
      totalChars: runningChars + systemChars + userChars,
    );
  }

  int _estimateChars(List<String> lines) {
    var chars = 0;
    for (final line in lines) {
      chars += line.length + 1;
    }
    return chars;
  }
}
