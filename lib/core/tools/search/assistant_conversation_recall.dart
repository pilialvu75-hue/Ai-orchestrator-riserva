import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';

/// Handles narrowly defined questions about names explicitly supplied by the
/// user in the current chat. It never infers a name from an Assistant message,
/// stores a profile, or reads any other conversation.
abstract final class AssistantConversationRecall {
  static final RegExp _selfDeclaration = RegExp(
    r"^(?:[Cc]iao[\s,;.!]*)?(?:[Mm]i chiamo|[Ii]l mio nome [èÈ]|"
    r"[Ii]o sono|[Ss]ono|[Jj]e m'appelle|[Jj]e suis|"
    r"[Mm]on nom est|[Mm]y name is)\s+"
    r"([\p{Lu}][\p{L}'’-]*)(?=\s|[.,;!?]|$)",
    unicode: true,
  );

  static final RegExp _friendDeclaration = RegExp(
    r"^(?:[Mm]on (?:pote|ami|copain)|[Mm]a (?:pote|copine)|"
    r"[Ii]l mio amico|[Ll]a mia amica)\s+"
    r"(?:s'appelle|est|si chiama)\s+"
    r"([\p{Lu}][\p{L}'’-]*)(?=\s|[.,;!?]|$)",
    unicode: true,
  );

  static const Set<String> _selfQuestions = <String>{
    'come mi chiamo',
    'qual è il mio nome',
    'quale è il mio nome',
    'qual é il mio nome',
    'ricordi il mio nome',
    'comment je m appelle',
    'quel est mon nom',
    'comment je me nomme',
    'what is my name',
    'what s my name',
    'como me llamo',
    'cómo me llamo',
  };

  static const Set<String> _friendQuestions = <String>{
    'comment s appelle mon pote',
    'comment s appelle mon ami',
    'comment s appelle mon copain',
    'comment s appelle ma copine',
    'comment se nomme mon pote',
    'come si chiama il mio amico',
    'come si chiama la mia amica',
    'what is my friend s name',
    'cómo se llama mi amigo',
  };

  static String? answer(String prompt, List<ChatTurn> context) {
    final question = _normalize(prompt);
    final isSelfQuestion = _selfQuestions.contains(question);
    final isFriendQuestion = _friendQuestions.contains(question);
    if (!isSelfQuestion && !isFriendQuestion) return null;

    final declaration = isSelfQuestion ? _selfDeclaration : _friendDeclaration;
    for (final turn in context.reversed) {
      if (turn.role != ChatRole.user || turn.excludeFromContext) continue;
      final name = declaration.firstMatch(turn.content.trim())?.group(1);
      if (name == null) continue;

      if (isSelfQuestion) {
        if (_isFrench(question)) return "Tu t'appelles $name.";
        if (_isEnglish(question)) return 'Your name is $name.';
        if (_isSpanish(question)) return 'Te llamas $name.';
        return 'Ti chiami $name.';
      }
      if (_isFrench(question)) return "Ton ami s'appelle $name.";
      if (_isEnglish(question)) return "Your friend's name is $name.";
      if (_isSpanish(question)) return 'Tu amigo se llama $name.';
      return 'Il tuo amico si chiama $name.';
    }

    return null;
  }

  static String _normalize(String prompt) => prompt
      .toLowerCase()
      .replaceAll('’', "'")
      .replaceAll(RegExp(r'[?!.,;:]+'), '')
      .replaceAll("'", ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _isFrench(String question) =>
      question.startsWith('comment ') || question.startsWith('quel ');
  static bool _isEnglish(String question) => question.startsWith('what ');
  static bool _isSpanish(String question) =>
      question.startsWith('como ') || question.startsWith('cómo ');
}
