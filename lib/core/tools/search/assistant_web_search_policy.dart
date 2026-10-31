/// Deterministic Assistant policy for deciding when fresh public web context
/// should be requested before inference.
///
/// This policy is intentionally runtime-neutral: Local, Hybrid and Cloud can
/// all use the same decision without making Internet access a property of a
/// specific model/provider.
abstract final class AssistantWebSearchPolicy {
  /// Internal marker carried in the system prompt when a caller explicitly
  /// requires an offline-only turn. Local prompt composition recognizes it and
  /// must not expose the model to the web-search tool protocol for that turn.
  static const String offlineOnlyMarker =
      '[AI_ORCHESTRATOR_WEB_ACCESS_DISABLED_OFFLINE]';

  static bool shouldSearch(String prompt) {
    final value = prompt.trim().toLowerCase();
    if (value.isEmpty) return false;

    if (_explicitNoWebIntent(value)) {
      return false;
    }

    // Explicit user-assigned variables are conversation-relative, not public facts.
    // Anchored forms leave mixed external-verification requests unchanged.
    if (_assignedValueRecall(value)) return false;

    return _explicitWebIntent(value) ||
        _timeSensitiveIntent(value) ||
        _shoppingIntent(value) ||
        isPresentOfficeHolderQuery(value) ||
        isSportsResultQuery(value) ||
        _evidenceDrivenIntent(value);
  }



  static bool _assignedValueRecall(String value) {
    final normalized = value.replaceAll('’', "'")
        .replaceAll(RegExp(r'\s+'), ' ');
    const variable = r'[a-z_][a-z0-9_]*';
    final patterns = <String>[
      r"^qual [èée] il valore (?:pi[uù] recente|attuale|ultimo) assegnato a " +
          variable + r" dall'utente[?.]?(?: rispondi solo con il numero\.?)?$",
      r'^what is the (?:latest|most recent|current) value assigned to ' +
          variable + r' by the user[?.]?$',
      r'^quelle est la (?:dernière valeur|valeur la plus récente|valeur actuelle) attribuée à ' +
          variable + r" par l'utilisateur[?.]?$",
      r'^cu[áa]l es el (?:último valor|valor más reciente|valor actual) asignado a ' +
          variable + r' por el usuario[?.]?$',
    ];
    return patterns.any((pattern) => RegExp(pattern).hasMatch(normalized));
  }

  /// Explicit verification of the preceding answer; not generic proofreading.
  static bool isAnswerVerification(String prompt) {
    final value = prompt.trim().toLowerCase().replaceAll('’', "'")
        .replaceAll(RegExp(r'[.!?]+$'), '').trim();
    return const <String>{
      'verifica la tua risposta', 'verifica questa risposta',
      'controlla le fonti della tua risposta',
      'fonti', 'le fonti',
      'sources', 'your sources', 'tes sources',
      'fuentes', 'las fuentes',
      'verify your answer', 'fact check your answer',
      'check the sources for your answer',
      'vérifie ta réponse', 'verifie ta reponse',
      'vérifie les sources de ta réponse',
      'verifica tu respuesta', 'verifica las fuentes de tu respuesta',
    }.contains(value);
  }

  /// Use the user's topic, never an assistant assertion as search evidence.
  static String? answerVerificationQuery(String prompt, String? previousUserPrompt) {
    if (!isAnswerVerification(prompt)) return null;
    final topic = previousUserPrompt?.trim();
    if (topic == null || topic.isEmpty || topic.length > 500 ||
        isAnswerVerification(topic) || _explicitNoWebIntent(topic.toLowerCase())) {
      return null;
    }
    return extractQuery(topic);
  }

  /// Competition and match results need evidence, including historical scores
  /// in French. A generic request for the result of a calculation is not a
  /// sports lookup and must not trigger public Web access.
  static bool isSportsResultQuery(String prompt) {
    final value = prompt.toLowerCase().replaceAll('’', "'");
    final competition = RegExp(
      r'\b(?:mondial[ei]|world cup|champions league|olimpiadi|olympics|'
      r'torneo|tournament|campionato|championnat|championnats|championship|'
      r'super bowl|match|matches|partita|partido|liga|ligue|football)\b',
    );
    final result = RegExp(
      r'\b(?:vinto|vincitore|vincitrice|risultato|risultati|'
      r'résultat|résultats|resultat|resultats|'
      r'won|winner|winners|score|scores|results|'
      r'gagné|gagnant|ganador|resultado|resultados)\b',
    );
    return competition.hasMatch(value) && result.hasMatch(value);
  }

  /// Short sports follow-ups may use only a preceding user match question.
  static bool isSportsResultFollowUp(String prompt) {
    final value = prompt.trim().toLowerCase().replaceAll('’', "'")
        .replaceAll(RegExp(r'[.?!…]+'), '').trim();
    return const <String>{
      "c'est quoi le résultat donc",
      "c'est quoi le résultat",
      "alors c'est quoi le résultat",
      'et le résultat',
      'quel est le score donc',
      'alors quel est le score',
      'quindi qual è il risultato',
      'e il risultato',
      'e il punteggio',
      "so what's the score",
      'what was the score then',
      'and the score',
      'y el resultado',
      'y cuál fue el resultado',
    }.contains(value);
  }

  static String? sportsResultFollowUpQuery(
    String userPrompt,
    String? precedingUserPrompt,
  ) {
    if (!isSportsResultFollowUp(userPrompt)) return null;
    final previous = precedingUserPrompt?.trim();
    if (previous == null || previous.isEmpty || previous.length > 300 ||
        previous.contains('\n') || previous.contains('\r') ||
        _explicitNoWebIntent(previous.toLowerCase().replaceAll('’', "'")) ||
        !isSportsResultQuery(previous)) {
      return null;
    }
    return extractQuery(previous);
  }

  /// Present-tense identity questions need fresh evidence even without "today".
  /// Explicit historical dates/ordinals remain ordinary knowledge questions.
  static bool isPresentOfficeHolderQuery(String prompt) {
    final value = prompt.toLowerCase().replaceAll('’', "'")
        .replaceAll('attualepresidente', 'attuale presidente');
    if (RegExp(r'\b(?:1[0-9]{3}|20[0-9]{2})\b').hasMatch(value) ||
        RegExp(r'\b(?:primo(?! ministro)|prima|first|premier(?! ministre)|première|primer|primero|primera|former|ex|era|stato|stata|was|était|fue)\b')
            .hasMatch(value)) {
      return false;
    }
    final identity = RegExp(
      r"(?:\bchi\s+(?:è|é|e'|e)|\bqual\s+(?:è|é|e'|e)|\bwho\s+is|\bqui\s+est|\bquién\s+es|\bquien\s+es)\s+",
    );
    final office = RegExp(
      r'\b(?:presidente|presidenti|presidents?|présidents?|présidente|sindaco|sindaca|mayor|maire|alcalde|alcaldesa|ceo|cancelliere|chancellor|primo ministro|prime minister|premier ministre)\b',
    );
    final recentList = RegExp(r'\b(?:ultim[ioae]|latest|last|current|recent|derniers?)\b').hasMatch(value);
    return (identity.hasMatch(value) || recentList) && office.hasMatch(value);
  }

  static bool _shoppingIntent(String value) {
    return RegExp(r'\b(?:cerca|cercami|cerco|trova|trovami|consigliami|find|search|cherche|busca)\b').hasMatch(value) &&
        RegExp(r'\b(?:offert[ae]|offera|scont[oi]|promozion[ei]|deals?|offers?)\b').hasMatch(value);
  }

  /// Returns true when a previous Assistant layer already supplied either live
  /// web evidence or an explicit best-effort failure marker.
  ///
  /// This prevents a Local model from re-emitting <search> after the
  /// Orchestrator (or the local tool recovery path) has already attempted the
  /// lookup for the same turn.
  static bool hasInjectedContext({
    required String prompt,
    String? systemPrompt,
  }) {
    final combined = '${systemPrompt ?? ''}\n$prompt'.toLowerCase();
    return combined.contains('[internet search results]') ||
        combined.contains('[web search results]') ||
        combined.contains('[web search unavailable]') ||
        combined.contains('web search results:\n');
  }

  static bool isOfflineOnly(String? systemPrompt) {
    return systemPrompt?.contains(offlineOnlyMarker) ?? false;
  }

  static String applyOfflineOnlyMarker(String? systemPrompt) {
    final base = systemPrompt?.trim();
    if (base == null || base.isEmpty) {
      return offlineOnlyMarker;
    }
    if (base.contains(offlineOnlyMarker)) return base;
    return '$base\n\n$offlineOnlyMarker';
  }

  static String extractQuery(String prompt) {
    var query = prompt.trim();
    if (query.isEmpty) return query;

    const prefixes = <String>[
      'cerca su internet ',
      'cerca sul web ',
      'cerca online ',
      'cercami online ',
      'ricerca su internet ',
      'ricerca sul web ',
      'ricerca online ',
      'cerca ',
      'cercami ',
      'trovami ',
      'search the web for ',
      'search online for ',
      'search for ',
      'search ',
      'look up online ',
      'look up ',
      'cherche en ligne ',
      'recherche en ligne ',
      'cherche ',
      'busca online ',
      'buscar online ',
      'busca ',
      'buscar ',
    ];

    final lower = query.toLowerCase();
    for (final prefix in prefixes) {
      if (lower.startsWith(prefix)) {
        final stripped = query.substring(prefix.length).trim();
        if (stripped.isNotEmpty) return stripped;
      }
    }

    return query;
  }

  static bool _explicitNoWebIntent(String value) {
    final normalized = value.replaceAll('’', "'");

    const phrases = <String>[
      // Italian.
      'non usare internet',
      'non usare il web',
      'non usare web',
      'non cercare online',
      'non cercare sul web',
      'non cercare su internet',
      'senza internet',
      'senza usare internet',
      'rispondi offline',
      'solo offline',

      // English.
      'do not use internet',
      "don't use internet",
      'do not use the web',
      "don't use the web",
      'do not search online',
      "don't search online",
      'do not search the web',
      "don't search the web",
      'without internet',
      'offline only',

      // French.
      "n'utilise pas internet",
      "n'utilise pas le web",
      'ne cherche pas en ligne',
      'ne cherche pas sur internet',
      'sans internet',
      'hors ligne uniquement',

      // Spanish.
      'no uses internet',
      'no uses la web',
      'no busques online',
      'no busques en internet',
      'no busques en la web',
      'sin internet',
      'solo sin conexión',
      'solo sin conexion',
    ];

    return phrases.any(normalized.contains);
  }

  /// A PDF's extracted text is untrusted. Only this *original user question*
  /// may grant limited permission to search the public web, and it must be
  /// short and explicitly ask for a search. Never pass document contents.
  static String? trustedDocumentWebQuery(String originalUserQuestion) {
    final question = originalUserQuestion.trim();
    if (question.isEmpty || question.length > 280 ||
        question.contains('\n') || question.contains('\r') ||
        question.contains('[INIZIO ESTRATTI')) {
      return null;
    }
    final normalized = question.toLowerCase().replaceAll('’', "'");
    if (_explicitNoWebIntent(normalized)) return null;
    // Anchor to a direct request, not an instruction quoted from a PDF
    // or a description of what the document happens to say.
    final online = RegExp(
      r'^(?:per favore\s+|please\s+)?'
      r'(?:cerca(?:mi)?|ricerca|verifica|controlla|'
      r'search|look up|verify|check|cherche|recherche|vérifie)'
      r'\s+(?:su\s+internet|sul\s+web|online|the\s+web|'
      r'online\s+for|en\s+ligne)\b',
    ).hasMatch(normalized);
    return online ? question : null;
  }

  static bool _explicitWebIntent(String value) {
    const phrases = <String>[
      'cerca online',
      'cerca sul web',
      'cerca su internet',
      'cercami online',
      'ricerca online',
      'ricerca sul web',
      'ricerca su internet',
      'search online',
      'search the web',
      'look up online',
      'cherche en ligne',
      'recherche en ligne',
      'busca online',
      'buscar online',
      'su internet',
      'on the web',
      'sur internet',
      'en internet',
    ];

    return phrases.any(value.contains);
  }

  static bool _timeSensitiveIntent(String value) {
    const markers = <String>[
      'meteo',
      'weather',
      'météo',
      'notizie',
      'news',
      'actualités',
      'actualites',
      'noticias',
      'aggiornamenti',
      'oggi',
      'today',
      "aujourd'hui",
      'hoy',
      'stasera',
      'tonight',
      'ce soir',
      'esta noche',
      'attuale',
      'attualmente',
      'current',
      'latest',
      'ultimo',
      'ultima',
      'ultime',
      'recent',
      'récent',
      'reciente',
      'in tempo reale',
      'real time',
      'en temps réel',
      'tiempo real',
      'chi gioca',
      'quando gioca',
      'risultato',
      'classifica',
      'standings',
      'score',
      'prezzo',
      'price',
      'prix',
      'precio',
      'quotazione',
      'exchange rate',
      'tasso di cambio',
    ];

    return markers.any(value.contains);
  }

  /// Some questions are not explicitly time-sensitive but still benefit from
  /// external evidence. Rankings, recommendations, comparisons, reviews and
  /// community opinion are examples: answering only from model memory can
  /// produce a plausible response without the evidence the user actually
  /// asked for.
  ///
  /// Keep this list deliberately narrower than generic quality words such as
  /// "good" or "buono" so ordinary explanatory prompts do not trigger a Web
  /// lookup unnecessarily.
  static bool _evidenceDrivenIntent(String value) {
    const phrases = <String>[
      // Italian.
      'il migliore',
      'la migliore',
      'i migliori',
      'le migliori',
      'miglior ',
      'top ',
      'recensione',
      'recensioni',
      'opinione',
      'opinioni',
      'pareri',
      'confronta ',
      'confronto ',
      'comparazione',
      'consigliami ',
      'mi consigli ',
      'raccomanda ',
      'raccomandazione',
      'vale la pena',
      'quale scegliere',
      'forum',
      'reddit',

      // English.
      'the best',
      'best ',
      'top ',
      'review ',
      'reviews',
      'opinion',
      'opinions',
      'compare ',
      'comparison',
      'recommend ',
      'recommendation',
      'worth it',
      'which should i choose',

      // French.
      'le meilleur',
      'la meilleure',
      'les meilleurs',
      'les meilleures',
      'avis ',
      'comparer ',
      'comparatif',
      'comparaison',
      'recommande ',
      'recommandation',
      'vaut le coup',
      'lequel choisir',
      'laquelle choisir',

      // Spanish.
      'el mejor',
      'la mejor',
      'los mejores',
      'las mejores',
      'reseña',
      'reseñas',
      'opinión',
      'opiniones',
      'comparar ',
      'comparación',
      'recomienda ',
      'recomendación',
      'vale la pena',
      'cuál elegir',
    ];

    if (phrases.any(value.contains)) return true;

    // Catch sentence-start forms that intentionally end with a space above,
    // without broadening matches to words such as "migliorare".
    const startPrefixes = <String>[
      'miglior ',
      'best ',
      'top ',
      'confronta ',
      'compare ',
      'comparer ',
      'comparar ',
    ];
    return startPrefixes.any(value.startsWith);
  }
}
