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

/// A directly stated, review-only vehicle color. No owner is inferred.
class AssistantNaturalCarColorCandidate {
  const AssistantNaturalCarColorCandidate({
    required this.color,
    required this.language,
    required this.originalStatement,
  });

  static const String recordKey = 'natural.user.car_color';

  final String color;
  final String language;
  final String originalStatement;
}

/// A reviewed change to an already confirmed car color.
class AssistantNaturalCarColorCorrectionCandidate {
  const AssistantNaturalCarColorCorrectionCandidate({
    required this.color,
    required this.language,
    required this.originalStatement,
    required this.correctedFact,
  });

  static const String recordKey = 'natural.user.car_color.pending_correction';

  final String color;
  final String language;
  final String originalStatement;
  final String correctedFact;
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

  // Closed first-person and one-word color vocabulary: not arbitrary facts.
  static final List<({
    String language,
    RegExp pattern,
    Set<String> colors,
  })> _carColorDeclarations = [
    (
      language: 'it',
      pattern: RegExp(r'^la mia (?:auto|macchina) è\s+(.+)$',
          caseSensitive: false),
      colors: {
        'blu', 'rossa', 'rosso', 'nera', 'nero', 'bianca', 'bianco',
        'grigia', 'grigio', 'verde', 'gialla', 'giallo',
      },
    ),
    (
      language: 'en',
      pattern: RegExp(r'^my car is\s+(.+)$', caseSensitive: false),
      colors: {'blue', 'red', 'black', 'white', 'grey', 'gray', 'green', 'yellow'},
    ),
    (
      language: 'fr',
      pattern: RegExp(r'^ma voiture est\s+(.+)$', caseSensitive: false),
      colors: {
        'bleue', 'bleu', 'rouge', 'noire', 'noir', 'blanche',
        'blanc', 'grise', 'gris', 'verte', 'vert', 'jaune',
      },
    ),
    (
      language: 'es',
      pattern: RegExp(r'^mi (?:coche|carro|auto) es\s+(.+)$',
          caseSensitive: false),
      colors: {
        'azul', 'rojo', 'roja', 'negro', 'negra', 'blanco', 'blanca',
        'gris', 'verde', 'amarillo', 'amarilla',
      },
    ),
  ];

  /// Only unambiguous first-person updates; no inferred contradictions.
  static final List<({
    String language,
    RegExp pattern,
    String prefix,
  })> _carColorCorrections = [
    (
      language: 'it',
      pattern: RegExp(
          r'^(?:la mia (?:auto|macchina) ora è|ho cambiato auto: ora è)\s+(.+)$',
          caseSensitive: false),
      prefix: 'La mia auto è ',
    ),
    (
      language: 'en',
      pattern: RegExp(r'^my car is now\s+(.+)$', caseSensitive: false),
      prefix: 'My car is ',
    ),
    (
      language: 'fr',
      pattern: RegExp(r'^ma voiture est maintenant\s+(.+)$',
          caseSensitive: false),
      prefix: 'Ma voiture est ',
    ),
    (
      language: 'es',
      pattern: RegExp(r'^mi (?:coche|carro|auto) ahora es\s+(.+)$',
          caseSensitive: false),
      prefix: 'Mi coche es ',
    ),
  ];

  static AssistantNaturalCarColorCorrectionCandidate?
      extractDirectUserCarColorCorrection(String input) {
    final statement = input.trim();
    if (statement.isEmpty ||
        statement.length > maxStatementChars ||
        statement.contains('\n') ||
        statement.contains('\r') ||
        statement.contains('://') ||
        statement.contains('@') ||
        statement.contains('=') ||
        statement.contains(';') ||
        statement.contains('"') ||
        statement.contains('“') ||
        statement.contains('”') ||
        statement.contains('«') ||
        statement.contains('»') ||
        statement.contains(String.fromCharCode(96)) ||
        statement.endsWith('?')) {
      return null;
    }

    final clean = statement.replaceFirst(RegExp(r'[.!]$'), '').trim();
    for (final correction in _carColorCorrections) {
      final match = correction.pattern.firstMatch(clean);
      if (match == null) continue;
      final color = match.group(1)!.trim().toLowerCase();
      final allowed = _carColorDeclarations
          .firstWhere((item) => item.language == correction.language)
          .colors;
      if (!allowed.contains(color)) return null;
      return AssistantNaturalCarColorCorrectionCandidate(
        color: color,
        language: correction.language,
        originalStatement: clean,
        correctedFact: correction.prefix + color,
      );
    }
    return null;
  }

  static AssistantNaturalCarColorCandidate? extractDirectUserCarColor(
      String input) {
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

    final clean = statement.replaceFirst(RegExp(r'[.!]$'), '').trim();
    for (final declaration in _carColorDeclarations) {
      final match = declaration.pattern.firstMatch(clean);
      if (match == null) continue;
      final color = match.group(1)!.trim().toLowerCase();
      if (!declaration.colors.contains(color)) return null;
      return AssistantNaturalCarColorCandidate(
        color: color,
        language: declaration.language,
        originalStatement: clean,
      );
    }
    return null;
  }

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
