import 'package:ai_orchestrator/core/orchestrator/task_type.dart';

/// Deterministic, keyword-based intent classifier.
///
/// No NLP models are used — purely rule-based matching to avoid
/// false positives. Web search keywords require context validation
/// to avoid intercepting legitimate chat messages like
/// "cerca di spiegarmi" or "cerca un esempio".
class IntentAnalyzer {
  const IntentAnalyzer();

  static const Set<String> _commandKeywords = {
    'apri', 'chiama', 'lancia',
  };

  static const Set<String> _planKeywords = {
    'pianifica', 'decomponi', 'orchestrate',
    'orchestrazione', 'pianificazione',
  };

  static const Set<String> _codingKeywords = {
    'implementa', 'implement', 'refactor', 'refactoring',
    'debug', 'bugfix', 'debugga', 'script', 'codice',
  };

  /// Keyword che da SOLE indicano con certezza una ricerca web.
  /// Non ambigue: nessun uso comune in chat normale.
  static const Set<String> _unambiguousWebKeywords = {
    'googla', 'google', 'cercami', 'trovami',
    'notizie', 'news', 'aggiornamenti',
  };

  /// Keyword ambigue che indicano web search SOLO se seguite da
  /// oggetto di ricerca, non da verbo/congiunzione.
  /// Es: "cerca orange road" → web, "cerca di spiegarmi" → chat.
  static const Set<String> _ambiguousWebKeywords = {
    'cerca', 'search', 'find', 'internet', 'online', 'web',
  };

  /// Parole che dopo una keyword ambigua indicano chat, NON web search.
  /// Es: "cerca DI", "cerca UN MODO", "search FOR AN EXAMPLE".
  static const Set<String> _chatContinuations = {
    'di', 'un', 'una', 'il', 'la', 'lo', 'gli', 'le', 'of',
    'a', 'an', 'the', 'to', 'for', 'modo', 'come', 'se',
    'qualcosa', 'qualcuno', 'di', 'che',
  };

  TaskType analyze(String input) {
    final tokens = input.toLowerCase().split(RegExp(r'\s+'));

    if (tokens.any(_commandKeywords.contains)) return TaskType.command;
    if (tokens.any(_planKeywords.contains)) return TaskType.plan;
    if (tokens.any(_codingKeywords.contains)) return TaskType.coding;
    if (_isWebSearch(tokens)) return TaskType.webSearch;

    return TaskType.chat;
  }

  bool _isWebSearch(List<String> tokens) {
    // Keyword non ambigue: bastano da sole
    if (tokens.any(_unambiguousWebKeywords.contains)) return true;

    // Keyword ambigue: servono controlli contestuali
    for (var i = 0; i < tokens.length; i++) {
      if (!_ambiguousWebKeywords.contains(tokens[i])) continue;

      // Se è l'ultimo token → probabile web ("cerca in internet")
      if (i == tokens.length - 1) return true;

      final next = tokens[i + 1];

      // "cerca di", "search for an", "find a way" → chat
      if (_chatContinuations.contains(next)) continue;

      // "cerca in internet", "search online" → web
      if (_ambiguousWebKeywords.contains(next)) return true;

      // "cerca [oggetto specifico]" → web
      // Il token successivo è un nome/oggetto, non una congiunzione
      return true;
    }

    return false;
  }
}
