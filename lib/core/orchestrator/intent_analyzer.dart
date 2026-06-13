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
  static const Set<String> _planKeywords = {
    'pianifica',
    'decomponi',
    'orchestrate',
    'orchestrazione',
    'pianificazione',
  };

  /// Italian/English trigger words for coding/debugging/refactoring tasks.
  static const Set<String> _codingKeywords = {
    'implementa',
    'implement',
    'refactor',
    'refactoring',
    'debug',
    'bugfix',
    'debugga',
    'script',
    'codice',
  };

  /// Italian/English trigger words for web search requests.
  /// Intercettati PRIMA di arrivare al modello locale, che non ha rete.
  static const Set<String> _webSearchKeywords = {
    'cerca',          // IT: search
    'search',         // EN
    'cercami',        // IT: search for me
    'googla',         // IT colloquial
    'google',
    'internet',
    'online',
    'web',
    'trovami',        // IT: find me
    'find',           // EN
    'notizie',        // IT: news
    'news',
    'aggiornamenti',  // IT: updates
  };

  /// Returns the [TaskType] that best matches [input].
  TaskType analyze(String input) {
    final tokens = input.toLowerCase().split(RegExp(r'\s+'));

    if (tokens.any(_commandKeywords.contains)) return TaskType.command;
    if (tokens.any(_planKeywords.contains)) return TaskType.plan;
    if (tokens.any(_codingKeywords.contains)) return TaskType.coding;
    if (tokens.any(_webSearchKeywords.contains)) return TaskType.webSearch;

    return TaskType.chat;
  }
}
