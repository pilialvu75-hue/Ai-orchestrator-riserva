/// Deterministic Assistant policy for deciding when fresh public web context
/// should be requested before inference.
///
/// This policy is intentionally runtime-neutral: Local, Hybrid and Cloud can
/// all use the same decision without making Internet access a property of a
/// specific model/provider.
abstract final class AssistantWebSearchPolicy {
  static bool shouldSearch(String prompt) {
    final value = prompt.trim().toLowerCase();
    if (value.isEmpty) return false;

    return _explicitWebIntent(value) || _timeSensitiveIntent(value);
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
