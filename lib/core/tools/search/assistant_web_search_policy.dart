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

    return _explicitWebIntent(value) ||
        _timeSensitiveIntent(value) ||
        isPresentOfficeHolderQuery(value) ||
        isSportsResultQuery(value) ||
        _evidenceDrivenIntent(value);
  }

  /// Competition results need evidence even when a year is supplied.
  static bool isSportsResultQuery(String prompt) {
    final value = prompt.toLowerCase();
    final competition = RegExp(
      r'\b(?:mondial[ei]|world cup|champions league|olimpiadi|olympics|torneo|tournament|campionato|championship|super bowl)\b',
    );
    final result = RegExp(
      r'\b(?:vinto|vincitore|vincitrice|risultato|risultati|won|winner|winners|score|results)\b',
    );
    return competition.hasMatch(value) && result.hasMatch(value);
  }

  /// Present-tense identity questions need fresh evidence even without "today".
  /// Explicit historical dates/ordinals remain ordinary knowledge questions.
  static bool isPresentOfficeHolderQuery(String prompt) {
    final value = prompt.toLowerCase().replaceAll('’', "'");
    if (RegExp(r'\b(?:1[0-9]{3}|20[0-9]{2})\b').hasMatch(value) ||
        RegExp(r'\b(?:primo(?! ministro)|prima|first|premier(?! ministre)|première|primer|primero|primera|former|ex|era|stato|stata|was|était|fue)\b')
            .hasMatch(value)) {
      return false;
    }
    final identity = RegExp(
      r"(?:\bchi\s+(?:è|e'|e)|\bqual\s+(?:è|e'|e)|\bwho\s+is|\bqui\s+est|\bquién\s+es|\bquien\s+es)\s+",
    );
    final office = RegExp(
      r'\b(?:presidente|president|président|présidente|sindaco|sindaca|mayor|maire|alcalde|alcaldesa|ceo|cancelliere|chancellor|primo ministro|prime minister|premier ministre)\b',
    );
    return identity.hasMatch(value) && office.hasMatch(value);
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
