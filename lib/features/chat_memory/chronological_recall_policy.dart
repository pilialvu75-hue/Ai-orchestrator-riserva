abstract final class ChronologicalRecallPolicy {
  static const int maxRecalledExchanges = 2;

  static bool shouldRecall(String userPrompt) {
    final normalized = _normalize(userPrompt);
    if (normalized.isEmpty) return false;

    // Ambiguous immediate references such as "quello di prima" stay on the
    // ordinary recent window. Deep recall is reserved for phrases that clearly
    // refer to an older discussion/decision.
    const referentialPhrases = <String>[
      // Italian.
      'come avevamo deciso',
      'come abbiamo deciso',
      'come avevamo detto',
      'come abbiamo detto',
      'come dicevi prima',
      'come dicevo prima',
      'ne parlavamo prima',
      'fai come abbiamo deciso',
      'torna al punto di prima',
      'riprendi da dove',
      'ti ricordi',
      'ricordi quando',
      'rileggi questa chat',
      'rileggere questa chat',
      'rileggi la conversazione',
      'rileggere la conversazione',

      // English.
      'what we discussed',
      'as we discussed',
      'as we decided',
      'what we decided',
      'earlier in this chat',
      'pick up where',
      'go back to the previous point',
      'do you remember',
      'you remember when',
      'reread this chat',
      'reread the conversation',

      // French.
      'comme on avait décidé',
      'comme nous avions décidé',
      'comme on a dit',
      'reprends où',
      'reprends la discussion',
      'tu te souviens',
      'relis cette conversation',

      // Spanish.
      'como decidimos',
      'como habíamos decidido',
      'como dijimos',
      'retoma donde',
      'retoma la conversación',
      'te acuerdas',
      'recuerdas cuando',
      'relee esta conversación',
    ];

    return referentialPhrases.any(normalized.contains);
  }

  /// Only an explicit, otherwise empty retry can inherit an unanswered turn's
  /// recall intent. A new request containing "retry" is not a continuation.
  static bool isRetry(String userPrompt) => const <String>{
    'riprova',
    'ritenta',
    'retry',
    'try again',
    'réessaie',
    'reintenta',
  }.contains(_normalize(userPrompt));

  static String _normalize(String input) {
    var value = input.trim().toLowerCase();
    value = value.replaceAll(RegExp(r'\s+'), ' ');
    value = value.replaceAll(RegExp(r'[.!?,;:…]+$'), '').trim();
    return value;
  }
}
