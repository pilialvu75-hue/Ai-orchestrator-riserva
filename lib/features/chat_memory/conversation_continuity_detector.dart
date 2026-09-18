abstract final class ConversationContinuityDetector {
  static const List<String> _deepReferenceCues = <String>[
    // Italian.
    'ti ricordi',
    'ricordi quando',
    'come avevamo',
    'come abbiamo deciso',
    'come abbiamo concordato',
    'quello di prima',
    'quella di prima',
    'quelli di prima',
    'quelle di prima',
    'messaggio precedente',
    'conversazione precedente',
    'discussione precedente',
    'ne avevamo parlato',
    'ne abbiamo parlato',
    'tempo fa',
    'riprendi da dove',
    'fai come abbiamo deciso',

    // English.
    'do you remember',
    'remember when',
    'as we decided',
    'as we agreed',
    'we decided before',
    'we agreed before',
    'the previous message',
    'previous conversation',
    'previous discussion',
    'the one from before',
    'we talked about this',
    'we discussed this',
    'earlier in this conversation',
    'pick up where we left off',

    // French.
    'tu te souviens',
    'vous vous souvenez',
    'comme on avait',
    'comme nous avions',
    'comme convenu',
    'message précédent',
    'conversation précédente',
    'discussion précédente',
    'on en avait parlé',
    'nous en avons parlé',
    'reprends où',

    // Spanish.
    'te acuerdas',
    'recuerdas cuando',
    'como habíamos',
    'como acordamos',
    'mensaje anterior',
    'conversación anterior',
    'discusión anterior',
    'habíamos hablado',
    'retoma donde',
    'continúa desde donde',
  ];

  static bool needsDeepHistory(String prompt) {
    final normalized = prompt.trim().toLowerCase();
    if (normalized.isEmpty) return false;

    for (final cue in _deepReferenceCues) {
      if (normalized.contains(cue)) {
        return true;
      }
    }
    return false;
  }
}
