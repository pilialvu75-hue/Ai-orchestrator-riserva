import 'package:ai_orchestrator/core/orchestrator/task_type.dart';

/// Deterministic, keyword-based intent classifier.
///
/// No NLP models are used — purely rule-based matching on lowercased,
/// whitespace-split tokens to avoid false positives from substrings.
class IntentAnalyzer {
  const IntentAnalyzer();

  /// Italian/English trigger words for platform commands.
  static const Set<String> _commandKeywords = {'apri', 'chiama', 'lancia'};

  /// Italian/English trigger words for multi-step planning (TaskWeaver-style).
  ///
  /// Chosen to be unambiguous technical terms unlikely to appear in everyday
  /// conversation.  The list can be extended without touching the routing logic.
  static const Set<String> _planKeywords = {
    'pianifica',   // IT: plan
    'decomponi',   // IT: decompose
    'orchestrate', // EN
    'orchestrazione', // IT
    'pianificazione', // IT: planning
  };

  /// Italian/English trigger words for coding/debugging/refactoring tasks.
  static const Set<String> _codingKeywords = {
    'implementa', // IT: implement
    'implement',  // EN
    'refactor',   // EN/IT
    'refactoring',
    'debug',
    'bugfix',
    'debugga',    // IT colloquial
    'script',
    'codice',     // IT: code
  };

  /// Returns the [TaskType] that best matches [input].
  TaskType analyze(String input) {
    final tokens = input.toLowerCase().split(RegExp(r'\s+'));

    if (tokens.any(_commandKeywords.contains)) return TaskType.command;
    if (tokens.any(_planKeywords.contains)) return TaskType.plan;
    if (tokens.any(_codingKeywords.contains)) return TaskType.coding;

    return TaskType.chat;
  }
}
