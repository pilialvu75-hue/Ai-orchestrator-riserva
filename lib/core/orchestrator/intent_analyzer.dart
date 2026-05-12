import 'package:ai_orchestrator/core/orchestrator/task_type.dart';

/// Deterministic, keyword-based intent classifier.
///
/// No NLP models are used — purely rule-based matching on lowercased,
/// whitespace-split tokens to avoid false positives from substrings.
class IntentAnalyzer {
  const IntentAnalyzer();

  static const Set<String> _commandKeywords = {'apri', 'chiama', 'lancia'};

  /// Returns the [TaskType] that best matches [input].
  TaskType analyze(String input) {
    final tokens = input.toLowerCase().split(RegExp(r'\s+'));
    if (tokens.any(_commandKeywords.contains)) {
      return TaskType.command;
    }
    return TaskType.chat;
  }
}
