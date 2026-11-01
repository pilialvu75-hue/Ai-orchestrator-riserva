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
    r"^(?:[Pp]er questa prova[,;:\s]+)?"
    r"(?:[Mm]on (?:pote|ami|copain)|[Mm]a (?:pote|copine)|"
    r"[Ii]l mio amico|[Ll]a mia amica)\s+"
    r"(?:s'appelle|est|si chiama)\s+"
    r"([\p{Lu}][\p{L}'’-]*)(?=\s|[.,;!?]|$)",
    unicode: true,
  );

  // Recall only statements made by the user in the current chat.
  static final RegExp _colleagueDeclaration = RegExp(
    r"^(?:[Ii]l nome del mio collega [èÈeE]|"
    r"[Ii]l mio collega si chiama|[Ll]a mia collega si chiama)\s+"
    r"([\p{Lu}][\p{L}'’-]*)(?=\s|[.,;!?]|$)",
    unicode: true,
  );

  static final RegExp _colleagueDescription = RegExp(
    r"^(?:[Ee]d?|[Ll]ui|[Ll]ei)\s+(?:[Ll]ui\s+|[Ll]ei\s+)?"
    r"(?:è|È|e')\s+(.+?)[.!?]*$",
  );

  static const Set<String> _colleagueNameQuestions = <String>{
    'come si chiama il mio collega',
    'come si chiama la mia collega',
    'qual è il nome del mio collega',
    'quale è il nome del mio collega',
    'qual e il nome del mio collega',
    'quale e il nome del mio collega',
    'qual è il nome della mia collega',
    'quale e il nome della mia collega',
  };

  static final RegExp _colleagueDescriptionQuestion = RegExp(
    r'^(?:e\s+)?(?:che cosa|cosa|che cos)\s+(?:è|e)(?:\s+(.+))?$',
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

  // Remove only conversational leading words, not arbitrary question text.
  // This covers "Ti ricordi come si chiama..." after reentering a chat and
  // "E come si chiama..." without introducing a new intent classifier.
  static String _questionBody(String question) {
    final withoutAnd = question.startsWith('e ')
        ? question.substring(2)
        : question;
    if (withoutAnd.startsWith('ti ricordi ')) {
      return withoutAnd.substring('ti ricordi '.length);
    }
    return withoutAnd;
  }

  // A question about a named person is not permission to search the Web or
  // claim to know them; answer only if the user named this friend in this chat.
  static final RegExp _namedFriendQuestion = RegExp(
    r"^(?:est(?:-|\s)ce que|est que) tu connais ([\p{L}][\p{L}'’-]*)$",
    unicode: true,
  );

  static String? answer(String prompt, List<ChatTurn> context) {
    final question = _normalize(prompt);
    final questionBody = _questionBody(question);
    final colleagueAnswer = _answerColleague(questionBody, context);
    if (colleagueAnswer != null) return colleagueAnswer;
    final isSelfQuestion = _selfQuestions.contains(questionBody);
    final namedFriend = _namedFriendQuestion.firstMatch(questionBody)?.group(1);
    final isFriendQuestion =
        _friendQuestions.contains(questionBody) || namedFriend != null;
    if (!isSelfQuestion && !isFriendQuestion) return null;

    final declaration = isSelfQuestion ? _selfDeclaration : _friendDeclaration;
    for (final turn in context.reversed) {
      if (turn.role != ChatRole.user || turn.excludeFromContext) continue;
      final name = declaration.firstMatch(turn.content.trim())?.group(1);
      if (name == null) continue;

      if (isSelfQuestion) {
        if (_isFrench(questionBody)) return "Tu t'appelles $name.";
        if (_isEnglish(question)) return 'Your name is $name.';
        if (_isSpanish(question)) return 'Te llamas $name.';
        return 'Ti chiami $name.';
      }
      if (namedFriend != null) {
        if (namedFriend != name.toLowerCase()) return null;
        return "Tu m'as dit que ton ami s'appelle $name, "
            "mais je ne le connais pas personnellement.";
      }
      if (_isFrench(questionBody)) return "Ton ami s'appelle $name.";
      if (_isEnglish(question)) return "Your friend's name is $name.";
      if (_isSpanish(question)) return 'Tu amigo se llama $name.';
      return 'Il tuo amico si chiama $name.';
    }

    return null;
  }

  static String? _answerColleague(String question, List<ChatTurn> context) {
    final isNameQuestion = _colleagueNameQuestions.contains(question);
    final descriptionQuestion = _colleagueDescriptionQuestion.firstMatch(question);
    if (!isNameQuestion && descriptionQuestion == null) return null;

    String? colleagueName;
    String? userDescription;
    bool colleagueIsCurrentTopic = false;
    for (final turn in context) {
      if (turn.excludeFromContext) {
        colleagueName = null;
        userDescription = null;
        colleagueIsCurrentTopic = false;
        continue;
      }
      if (turn.role != ChatRole.user) continue;
      final text = turn.content.trim();
      final declaration = _colleagueDeclaration.firstMatch(text);
      if (declaration != null) {
        colleagueName = declaration.group(1);
        userDescription = null;
        colleagueIsCurrentTopic = true;
        continue;
      }
      final description = _colleagueDescription.firstMatch(text);
      if (colleagueIsCurrentTopic && colleagueName != null &&
          description != null) {
        userDescription = description.group(1)?.trim();
        continue;
      }
      final normalized = _normalize(text);
      if (_colleagueNameQuestions.contains(normalized) ||
          _colleagueDescriptionQuestion.hasMatch(normalized)) {
        colleagueIsCurrentTopic = true;
      } else {
        colleagueIsCurrentTopic = false;
      }
    }
    if (colleagueName == null) return null;

    if (isNameQuestion) return 'Il tuo collega si chiama $colleagueName.';
    final mentionedSubject = descriptionQuestion?.group(1)?.trim();
    if (mentionedSubject != null && mentionedSubject.isNotEmpty &&
        mentionedSubject.toLowerCase() != colleagueName.toLowerCase() &&
        mentionedSubject != 'il mio collega' &&
        mentionedSubject != 'il tuo collega' &&
        mentionedSubject != 'la mia collega') {
      return null;
    }
    if (userDescription == null || userDescription.isEmpty) return null;
    return 'Hai detto che il tuo collega $colleagueName è $userDescription.';
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
