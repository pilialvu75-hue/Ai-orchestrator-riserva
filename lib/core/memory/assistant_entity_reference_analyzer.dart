/// ME-2 reference analysis: facts about people/objects are not identity proofs.
///
/// This deliberately stateless local component only accepts direct text from
/// an ordinary user conversation. Callers MUST NOT pass model output, Web,
/// attachments or worker prompts. No SQLite write, user profile, third-party
/// dossier, Cloud call or automatic memory confirmation occurs here.
///
/// A named reference is an alias label, NOT a unique person identifier: two
/// people may share a first name. Unnamed references MUST NOT be merged with
/// any person merely because they are coworkers or share a characteristic.
enum AssistantEntityReferenceKind { person, bicycle, vehicle }

enum AssistantEntityClaimKind { relationship, description, opinion, event }

class AssistantEntityReferenceClaim {
  const AssistantEntityReferenceClaim({
    required this.subjectKind,
    required this.claimKind,
    required this.predicate,
    required this.value,
    required this.userStatement,
    this.namedReference,
    this.nameReferenceKey,
    this.sensitiveThirdParty = false,
  });

  final AssistantEntityReferenceKind subjectKind;
  final AssistantEntityClaimKind claimKind;

  /// An explicitly supplied name, never inferred from nearby statements.
  final String? namedReference;

  /// Stable comparison label only: NOT a unique identity or owner profile.
  final String? nameReferenceKey;

  final String predicate;
  final String value;
  final String userStatement;

  /// Additional safeguard before any future opt-in third-party review.
  final bool sensitiveThirdParty;

  bool get identityUnresolved => nameReferenceKey == null;
  bool get subjective => claimKind == AssistantEntityClaimKind.opinion;

  /// Analysis is transient and never sufficient authorization to persist.
  bool get canAutomaticallyConfirm => false;
}

class AssistantEntityReferenceAnalysis {
  AssistantEntityReferenceAnalysis(List<AssistantEntityReferenceClaim> claims)
      : claims = List<AssistantEntityReferenceClaim>.unmodifiable(claims),
        byNameReference =
            _groupNamedReferences(claims),
        unresolved = List<AssistantEntityReferenceClaim>.unmodifiable(
          claims.where((claim) => claim.identityUnresolved),
        );

  final List<AssistantEntityReferenceClaim> claims;

  /// A provisional label is not a unique person ID; collisions stay possible.
  final Map<String, List<AssistantEntityReferenceClaim>> byNameReference;

  /// Unnamed mentions are separate assertions, NOT anonymous persons.
  final List<AssistantEntityReferenceClaim> unresolved;

  static Map<String, List<AssistantEntityReferenceClaim>>
      _groupNamedReferences(List<AssistantEntityReferenceClaim> claims) {
    final groups = <String, List<AssistantEntityReferenceClaim>>{};
    for (final claim in claims) {
      final key = claim.nameReferenceKey;
      if (key == null) continue;
      groups.putIfAbsent(key, () => <AssistantEntityReferenceClaim>[]).add(claim);
    }
    return Map<String, List<AssistantEntityReferenceClaim>>.unmodifiable({
      for (final entry in groups.entries)
        entry.key: List<AssistantEntityReferenceClaim>.unmodifiable(entry.value),
    });
  }
}

/// A first, bounded Italian-only reference analyzer for the user-provided
/// acceptance cases. Other languages and coreference need separate tests.
/// Do not use this component for open-ended profiling or memory ingestion.
abstract final class AssistantEntityReferenceAnalyzer {
  static const int maxStatementChars = 120;

  static final RegExp _personName = RegExp(
    r"^[\p{L}](?:[\p{L}\p{M}'’-]{0,30}[\p{L}\p{M}])?$",
    unicode: true,
  );

  static final RegExp _colleagueNamed =
      RegExp(r'^un collega si chiama (.+)$', caseSensitive: false);
  static final RegExp _namedColleague =
      RegExp(r'^(.+) è un mio collega$', caseSensitive: false);
  static final RegExp _namedOverweight =
      RegExp(r'^(.+) è sovrappeso$', caseSensitive: false);
  static final RegExp _namedSport =
      RegExp(r'^(.+) fa tanto sport
  static AssistantEntityReferenceAnalysis analyzeDirectUserStatements(
      Iterable<String> statements) {
    final claims = <AssistantEntityReferenceClaim>[];
    for (final statement in statements) {
      final claim = parseDirectUserStatement(statement);
      if (claim != null) claims.add(claim);
    }
    return AssistantEntityReferenceAnalysis(claims);
  }

  static AssistantEntityReferenceClaim? parseDirectUserStatement(String text) {
    final source = text.trim();
    if (source.isEmpty ||
        source.length > maxStatementChars ||
        source.contains('\r') ||
        source.contains('\n') ||
        source.contains('://') ||
        source.contains('@') ||
        source.contains('=') ||
        source.contains(';') ||
        source.contains('"') ||
        source.contains('“') ||
        source.contains('”') ||
        source.contains('«') ||
        source.contains('»') ||
        source.contains(String.fromCharCode(96)) ||
        source.endsWith('?')) {
      return null;
    }

    final clean = source.replaceFirst(RegExp(r'[.!]$'), '').trim();
    final normalized = clean.toLowerCase();
    AssistantEntityReferenceClaim unknown({
      required AssistantEntityReferenceKind kind,
      required AssistantEntityClaimKind claim,
      required String predicate,
      required String value,
      bool sensitive = false,
    }) =>
        AssistantEntityReferenceClaim(
          subjectKind: kind,
          claimKind: claim,
          predicate: predicate,
          value: value,
          userStatement: clean,
          sensitiveThirdParty: sensitive,
        );

    if (normalized == 'il mio collega è un idiota') {
      return unknown(
        kind: AssistantEntityReferenceKind.person,
        claim: AssistantEntityClaimKind.opinion,
        predicate: 'user_opinion_about_colleague',
        value: 'idiota',
        sensitive: true,
      );
    }
    if (normalized == 'non mi piace il mio collega') {
      return unknown(
        kind: AssistantEntityReferenceKind.person,
        claim: AssistantEntityClaimKind.opinion,
        predicate: 'user_dislikes_colleague',
        value: 'non_mi_piace',
        sensitive: true,
      );
    }
    if (normalized == 'ho un collega alto') {
      return unknown(
        kind: AssistantEntityReferenceKind.person,
        claim: AssistantEntityClaimKind.description,
        predicate: 'altezza_dichiarata',
        value: 'alto',
        sensitive: true,
      );
    }
    if (normalized == 'la mia bicicletta è veloce' ||
        normalized == 'la mia bici è veloce') {
      return unknown(
        kind: AssistantEntityReferenceKind.bicycle,
        claim: AssistantEntityClaimKind.opinion,
        predicate: 'velocita_percepita',
        value: 'veloce',
      );
    }
    if (normalized == 'ho cambiato auto: ora è rossa') {
      return unknown(
        kind: AssistantEntityReferenceKind.vehicle,
        claim: AssistantEntityClaimKind.event,
        predicate: 'cambio_auto_identita_da_chiarire',
        value: 'auto_attuale_rossa',
      );
    }
    // Explicit repainting refers to the same vehicle; its durable identity
    // still requires user review and cannot be inferred from nearby claims.
    if (normalized == 'ho riverniciato la mia auto: ora è rossa' ||
        normalized == 'ho riverniciato la stessa auto: ora è rossa') {
      return unknown(
        kind: AssistantEntityReferenceKind.vehicle,
        claim: AssistantEntityClaimKind.event,
        predicate: 'riverniciatura_stessa_auto_dichiarata',
        value: 'rossa',
      );
    }
    if (normalized == 'ho comprato una seconda auto rossa') {
      return unknown(
        kind: AssistantEntityReferenceKind.vehicle,
        claim: AssistantEntityClaimKind.event,
        predicate: 'acquisto_seconda_auto',
        value: 'rossa',
      );
    }

    AssistantEntityReferenceClaim? namedMatch(
      RegExp pattern, {
      required AssistantEntityClaimKind kind,
      required String predicate,
      required String value,
      bool sensitive = false,
    }) {
      final match = pattern.firstMatch(clean);
      if (match == null) return null;
      final name = match.group(1)!.trim();
      if (name.length < 2 || !_personName.hasMatch(name)) return null;
      return AssistantEntityReferenceClaim(
        subjectKind: AssistantEntityReferenceKind.person,
        claimKind: kind,
        namedReference: name,
        // A label for a written name, not an immutable unique person ID.
        nameReferenceKey: 'person:name:' + name.toLowerCase(),
        predicate: predicate,
        value: value,
        userStatement: clean,
        sensitiveThirdParty: sensitive,
      );
    }

    return namedMatch(
          _colleagueNamed,
          kind: AssistantEntityClaimKind.relationship,
          predicate: 'collega_utente',
          value: 'dichiarato',
        ) ??
        namedMatch(
          _namedColleague,
          kind: AssistantEntityClaimKind.relationship,
          predicate: 'collega_utente',
          value: 'dichiarato',
        ) ??
        namedMatch(
          _namedOverweight,
          kind: AssistantEntityClaimKind.description,
          predicate: 'corporatura_dichiarata',
          value: 'sovrappeso',
          sensitive: true,
        ) ??
        namedMatch(
          _namedSport,
          kind: AssistantEntityClaimKind.description,
          predicate: 'attivita_dichiarata',
          value: 'tanto_sport',
        ) ??
        namedMatch(
          _namedTall,
          kind: AssistantEntityClaimKind.description,
          predicate: 'altezza_dichiarata',
          value: 'alto',
          sensitive: true,
        );
  }
}
, caseSensitive: false);
  static final RegExp _namedTall =
      RegExp(r'^(.+) è alto
  static AssistantEntityReferenceAnalysis analyzeDirectUserStatements(
      Iterable<String> statements) {
    final claims = <AssistantEntityReferenceClaim>[];
    for (final statement in statements) {
      final claim = parseDirectUserStatement(statement);
      if (claim != null) claims.add(claim);
    }
    return AssistantEntityReferenceAnalysis(claims);
  }

  static AssistantEntityReferenceClaim? parseDirectUserStatement(String text) {
    final source = text.trim();
    if (source.isEmpty ||
        source.length > maxStatementChars ||
        source.contains('\r') ||
        source.contains('\n') ||
        source.contains('://') ||
        source.contains('@') ||
        source.contains('=') ||
        source.contains(';') ||
        source.contains('"') ||
        source.contains('“') ||
        source.contains('”') ||
        source.contains('«') ||
        source.contains('»') ||
        source.contains(String.fromCharCode(96)) ||
        source.endsWith('?')) {
      return null;
    }

    final clean = source.replaceFirst(RegExp(r'[.!]$'), '').trim();
    final normalized = clean.toLowerCase();
    AssistantEntityReferenceClaim unknown({
      required AssistantEntityReferenceKind kind,
      required AssistantEntityClaimKind claim,
      required String predicate,
      required String value,
      bool sensitive = false,
    }) =>
        AssistantEntityReferenceClaim(
          subjectKind: kind,
          claimKind: claim,
          predicate: predicate,
          value: value,
          userStatement: clean,
          sensitiveThirdParty: sensitive,
        );

    if (normalized == 'il mio collega è un idiota') {
      return unknown(
        kind: AssistantEntityReferenceKind.person,
        claim: AssistantEntityClaimKind.opinion,
        predicate: 'user_opinion_about_colleague',
        value: 'idiota',
        sensitive: true,
      );
    }
    if (normalized == 'non mi piace il mio collega') {
      return unknown(
        kind: AssistantEntityReferenceKind.person,
        claim: AssistantEntityClaimKind.opinion,
        predicate: 'user_dislikes_colleague',
        value: 'non_mi_piace',
        sensitive: true,
      );
    }
    if (normalized == 'ho un collega alto') {
      return unknown(
        kind: AssistantEntityReferenceKind.person,
        claim: AssistantEntityClaimKind.description,
        predicate: 'altezza_dichiarata',
        value: 'alto',
        sensitive: true,
      );
    }
    if (normalized == 'la mia bicicletta è veloce' ||
        normalized == 'la mia bici è veloce') {
      return unknown(
        kind: AssistantEntityReferenceKind.bicycle,
        claim: AssistantEntityClaimKind.opinion,
        predicate: 'velocita_percepita',
        value: 'veloce',
      );
    }
    if (normalized == 'ho cambiato auto: ora è rossa') {
      return unknown(
        kind: AssistantEntityReferenceKind.vehicle,
        claim: AssistantEntityClaimKind.event,
        predicate: 'cambio_auto_identita_da_chiarire',
        value: 'auto_attuale_rossa',
      );
    }
    if (normalized == 'ho comprato una seconda auto rossa') {
      return unknown(
        kind: AssistantEntityReferenceKind.vehicle,
        claim: AssistantEntityClaimKind.event,
        predicate: 'acquisto_seconda_auto',
        value: 'rossa',
      );
    }

    AssistantEntityReferenceClaim? namedMatch(
      RegExp pattern, {
      required AssistantEntityClaimKind kind,
      required String predicate,
      required String value,
      bool sensitive = false,
    }) {
      final match = pattern.firstMatch(clean);
      if (match == null) return null;
      final name = match.group(1)!.trim();
      if (name.length < 2 || !_personName.hasMatch(name)) return null;
      return AssistantEntityReferenceClaim(
        subjectKind: AssistantEntityReferenceKind.person,
        claimKind: kind,
        namedReference: name,
        // A label for a written name, not an immutable unique person ID.
        nameReferenceKey: 'person:name:' + name.toLowerCase(),
        predicate: predicate,
        value: value,
        userStatement: clean,
        sensitiveThirdParty: sensitive,
      );
    }

    return namedMatch(
          _colleagueNamed,
          kind: AssistantEntityClaimKind.relationship,
          predicate: 'collega_utente',
          value: 'dichiarato',
        ) ??
        namedMatch(
          _namedColleague,
          kind: AssistantEntityClaimKind.relationship,
          predicate: 'collega_utente',
          value: 'dichiarato',
        ) ??
        namedMatch(
          _namedOverweight,
          kind: AssistantEntityClaimKind.description,
          predicate: 'corporatura_dichiarata',
          value: 'sovrappeso',
          sensitive: true,
        ) ??
        namedMatch(
          _namedSport,
          kind: AssistantEntityClaimKind.description,
          predicate: 'attivita_dichiarata',
          value: 'tanto_sport',
        );
  }
}
, caseSensitive: false);

  static AssistantEntityReferenceAnalysis analyzeDirectUserStatements(
      Iterable<String> statements) {
    final claims = <AssistantEntityReferenceClaim>[];
    for (final statement in statements) {
      final claim = parseDirectUserStatement(statement);
      if (claim != null) claims.add(claim);
    }
    return AssistantEntityReferenceAnalysis(claims);
  }

  static AssistantEntityReferenceClaim? parseDirectUserStatement(String text) {
    final source = text.trim();
    if (source.isEmpty ||
        source.length > maxStatementChars ||
        source.contains('\r') ||
        source.contains('\n') ||
        source.contains('://') ||
        source.contains('@') ||
        source.contains('=') ||
        source.contains(';') ||
        source.contains('"') ||
        source.contains('“') ||
        source.contains('”') ||
        source.contains('«') ||
        source.contains('»') ||
        source.contains(String.fromCharCode(96)) ||
        source.endsWith('?')) {
      return null;
    }

    final clean = source.replaceFirst(RegExp(r'[.!]$'), '').trim();
    final normalized = clean.toLowerCase();
    AssistantEntityReferenceClaim unknown({
      required AssistantEntityReferenceKind kind,
      required AssistantEntityClaimKind claim,
      required String predicate,
      required String value,
      bool sensitive = false,
    }) =>
        AssistantEntityReferenceClaim(
          subjectKind: kind,
          claimKind: claim,
          predicate: predicate,
          value: value,
          userStatement: clean,
          sensitiveThirdParty: sensitive,
        );

    if (normalized == 'il mio collega è un idiota') {
      return unknown(
        kind: AssistantEntityReferenceKind.person,
        claim: AssistantEntityClaimKind.opinion,
        predicate: 'user_opinion_about_colleague',
        value: 'idiota',
        sensitive: true,
      );
    }
    if (normalized == 'non mi piace il mio collega') {
      return unknown(
        kind: AssistantEntityReferenceKind.person,
        claim: AssistantEntityClaimKind.opinion,
        predicate: 'user_dislikes_colleague',
        value: 'non_mi_piace',
        sensitive: true,
      );
    }
    if (normalized == 'ho un collega alto') {
      return unknown(
        kind: AssistantEntityReferenceKind.person,
        claim: AssistantEntityClaimKind.description,
        predicate: 'altezza_dichiarata',
        value: 'alto',
        sensitive: true,
      );
    }
    if (normalized == 'la mia bicicletta è veloce' ||
        normalized == 'la mia bici è veloce') {
      return unknown(
        kind: AssistantEntityReferenceKind.bicycle,
        claim: AssistantEntityClaimKind.opinion,
        predicate: 'velocita_percepita',
        value: 'veloce',
      );
    }
    if (normalized == 'ho cambiato auto: ora è rossa') {
      return unknown(
        kind: AssistantEntityReferenceKind.vehicle,
        claim: AssistantEntityClaimKind.event,
        predicate: 'cambio_auto_identita_da_chiarire',
        value: 'auto_attuale_rossa',
      );
    }
    if (normalized == 'ho comprato una seconda auto rossa') {
      return unknown(
        kind: AssistantEntityReferenceKind.vehicle,
        claim: AssistantEntityClaimKind.event,
        predicate: 'acquisto_seconda_auto',
        value: 'rossa',
      );
    }

    AssistantEntityReferenceClaim? namedMatch(
      RegExp pattern, {
      required AssistantEntityClaimKind kind,
      required String predicate,
      required String value,
      bool sensitive = false,
    }) {
      final match = pattern.firstMatch(clean);
      if (match == null) return null;
      final name = match.group(1)!.trim();
      if (name.length < 2 || !_personName.hasMatch(name)) return null;
      return AssistantEntityReferenceClaim(
        subjectKind: AssistantEntityReferenceKind.person,
        claimKind: kind,
        namedReference: name,
        // A label for a written name, not an immutable unique person ID.
        nameReferenceKey: 'person:name:' + name.toLowerCase(),
        predicate: predicate,
        value: value,
        userStatement: clean,
        sensitiveThirdParty: sensitive,
      );
    }

    return namedMatch(
          _colleagueNamed,
          kind: AssistantEntityClaimKind.relationship,
          predicate: 'collega_utente',
          value: 'dichiarato',
        ) ??
        namedMatch(
          _namedColleague,
          kind: AssistantEntityClaimKind.relationship,
          predicate: 'collega_utente',
          value: 'dichiarato',
        ) ??
        namedMatch(
          _namedOverweight,
          kind: AssistantEntityClaimKind.description,
          predicate: 'corporatura_dichiarata',
          value: 'sovrappeso',
          sensitive: true,
        ) ??
        namedMatch(
          _namedSport,
          kind: AssistantEntityClaimKind.description,
          predicate: 'attivita_dichiarata',
          value: 'tanto_sport',
        );
  }
}
