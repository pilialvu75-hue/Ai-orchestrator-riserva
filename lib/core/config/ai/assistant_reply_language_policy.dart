/// A lightweight language hint for ordinary Assistant turns.
///
/// The UI locale and the language of the previous response must not override
/// an unambiguous new user message. Ambiguous messages add no hint and remain
/// governed by the configured system prompt.
abstract final class AssistantReplyLanguagePolicy {
  static const Map<String, Set<String>> _signals = <String, Set<String>>{
    'Italian': <String>{
      'ciao', 'sono', 'come', 'chiamo', 'chiama', 'vorrei', 'sapere',
      'mio', 'amico', 'alto', 'anni', 'perché', 'cosa', 'posso',
      'italiano', 'grazie', 'questa', 'questo', 'rispondi',
    },
    'French': <String>{
      'bonjour', 'comment', 'mon', 'pote', "s'appelle", 'suis', 'est',
      'résultat', 'championnat', 'votre', 'prénom', 'peux',
      'pouvez', 'vous', 'merci', 'français', 'quelle',
    },
    'English': <String>{
      'hello', 'what', 'how', 'my', 'name', 'friend', 'please',
      'can', 'you', 'your', 'this', 'the', 'thanks', 'english',
      'where', 'why', 'tell',
    },
    'Spanish': <String>{
      'hola', 'cómo', 'llamo', 'amigo', 'nombre', 'gracias',
      'español', 'puedes', 'quiero', 'qué', 'dónde', 'puedo', 'soy',
    },
  };

  // Whole-turn matches keep quoted text and mixed greetings as ordinary data.
  // Hints apply only to this response and are never persisted.
  static const Map<String, String> _shortTurns = <String, String>{
    'ciao': 'Italian',
    'bonjour': 'French',
    'hello': 'English',
    'hola': 'Spanish',
    'parlami in italiano': 'Italian',
    'rispondi in italiano': 'Italian',
    'reply in italian': 'Italian',
    'réponds en italien': 'Italian',
    'responde en italiano': 'Italian',
    'parlami in inglese': 'English',
    'rispondi in inglese': 'English',
    'reply in english': 'English',
    'réponds en anglais': 'English',
    'responde en inglés': 'English',
    'parlami in francese': 'French',
    'rispondi in francese': 'French',
    'reply in french': 'French',
    'réponds en français': 'French',
    'responde en francés': 'French',
    'parlami in spagnolo': 'Spanish',
    'rispondi in spagnolo': 'Spanish',
    'reply in spanish': 'Spanish',
    'réponds en espagnol': 'Spanish',
    'responde en español': 'Spanish',
  };

  // A complete, short Italian named-person statement is unambiguous even
  // when the vocabulary scorer sees only "alto". Keep these patterns bounded
  // to the reviewed relational-memory phrases; do not guess on a single word.
  static final RegExp _shortItalianNamedStatement = RegExp(
    r"^(?:[\p{L}\p{M}'’-]+\s+è\s+alto|"
    r"non\s+[\p{L}\p{M}'’-]+\s*,\s*[\p{L}\p{M}'’-]+\s+è\s+alto)$",
    unicode: true,
    caseSensitive: false,
  );

  /// Returns null when a message is too short or mixed to classify safely.
  static String? detect(String userPrompt) {
    final text = userPrompt.trim().toLowerCase();
    if (text.isEmpty) return null;
    final wholeTurn = text.replaceAll(RegExp(r'[.!?]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ').trim();
    final explicitLanguage = _shortTurns[wholeTurn];
    if (explicitLanguage != null) return explicitLanguage;
    if (_shortItalianNamedStatement.hasMatch(wholeTurn)) return 'Italian';
    final words = RegExp(
      r"[\p{L}]+(?:['’][\p{L}]+)?",
      unicode: true,
    ).allMatches(text).map((match) => match.group(0)!).toList();
    if (words.isEmpty) return null;

    String? best;
    var bestScore = 1;
    var tied = false;
    for (final entry in _signals.entries) {
      final score = words.where(entry.value.contains).length;
      if (score > bestScore) {
        best = entry.key;
        bestScore = score;
        tied = false;
      } else if (score == bestScore && score > 1) {
        tied = true;
      }
    }
    return tied ? null : best;
  }

  static String withCurrentTurnHint({
    required String systemPrompt,
    required String userPrompt,
  }) {
    final language = detect(userPrompt);
    if (language == null) return systemPrompt;
    return '$systemPrompt\n\nFor this response, write in $language. '
        'The latest user message determines the reply language, even when '
        'earlier messages used another language. Preserve proper names.';
  }
}
