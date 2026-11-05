/// Conservative and offline first-pass extraction of direct user statements.
///
/// This parser must only receive the typed user message of an ordinary chat,
/// never assistant output, imported documents, tool results or quoted text.
/// Recognition is intentionally narrow: no inference or automatic confirmation.
class AssistantNaturalNameCandidate {
  const AssistantNaturalNameCandidate({
    required this.givenName,
    required this.language,
    required this.originalStatement,
  });

  static const String recordKey = 'natural.user.given_name';

  final String givenName;
  final String language;
  final String originalStatement;
}

abstract final class AssistantNaturalMemoryCandidateExtractor {
  static const int maxStatementChars = 96;

  // One declared given name only, with Unicode accents and basic punctuation.
  // A full name, address, contact, secret or additional proposition is outside
  // this narrow first tranche, and cannot be inferred from the model.
  static final RegExp _name = RegExp(
    r"^[\p{L}](?:[\p{L}\p{M}'’-]{0,30}[\p{L}\p{M}])?$",
    unicode: true,
  );

  static final List<({String language, RegExp pattern})> _declarations = [
    (
      language: 'it',
      pattern: RegExp(r'^mi chiamo\s+(.+)$', caseSensitive: false),
    ),
    (
      language: 'en',
      pattern: RegExp(r'^my name is\s+(.+)$', caseSensitive: false),
    ),
    (
      language: 'en',
      pattern: RegExp(r"^i(?:'m|’m| am)\s+(.+)$", caseSensitive: false),
    ),
    (
      language: 'fr',
      pattern: RegExp(r"^je m['’]appelle\s+(.+)$", caseSensitive: false),
    ),
    (
      language: 'es',
      pattern: RegExp(r'^me llamo\s+(.+)$', caseSensitive: false),
    ),
  ];

  // A deliberately small ambiguity filter for informal English "I'm ...".
  // Unrecognized adjectives still stay review-only candidates.
  static const Set<String> _notNames = {
    'not', 'happy', 'sad', 'tired', 'ready', 'fine', 'okay', 'ok',
    'here', 'there', 'sorry', 'hungry', 'busy', 'sure', 'lost',
    'confused', 'alone', 'sick', 'well', 'late', 'early',
  };

  static AssistantNaturalNameCandidate? extractDirectUserName(String input) {
    final statement = input.trim();
    if (statement.isEmpty ||
        statement.length > maxStatementChars ||
        statement.contains('\n') ||
        statement.contains('\r') ||
        statement.contains('://') ||
        statement.contains('@') ||
        statement.contains('=') ||
        statement.contains(':') ||
        statement.contains('"') ||
        statement.contains('“') ||
        statement.contains('”') ||
        statement.contains('«') ||
        statement.contains('»') ||
        statement.contains(String.fromCharCode(96)) ||
        statement.endsWith('?')) {
      return null;
    }

    final withoutPunctuation =
        statement.replaceFirst(RegExp(r'[.!]$'), '').trim();
    for (final declaration in _declarations) {
      final match = declaration.pattern.firstMatch(withoutPunctuation);
      if (match == null) continue;
      final name = match.group(1)!.trim();
      if (name.length < 2 ||
          name.length > 32 ||
          !_name.hasMatch(name) ||
          _notNames.contains(name.toLowerCase())) {
        return null;
      }
      return AssistantNaturalNameCandidate(
        givenName: name,
        language: declaration.language,
        originalStatement: withoutPunctuation,
      );
    }
    return null;
  }
}
