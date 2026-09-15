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

    return _explicitWebIntent(value) || _timeSensitiveIntent(value);
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
}
