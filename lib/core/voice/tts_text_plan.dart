/// Conservative, offline IT/FR/EN routing. Ambiguous text uses the app locale.
String detectTtsLanguage(String text, String fallback) {
  final words = RegExp(r"[a-zà-ÿ]+")
      .allMatches(text.toLowerCase())
      .map((m) => m.group(0)!)
      .toSet();
  const vocabulary = <String, String>{
    'it': 'ciao buongiorno buonasera grazie prego sono siamo questo questa questi queste della delle degli nella nelle perché quindi anche oppure puoi posso vuoi vorrei italiano italiana come stai buongiorno',
    'fr': 'bonjour bonsoir salut merci voici voilà avec vous nous votre notre cette ces dans pour est sont une des les aux du au pas mais français française comment allez aujourd hui',
    'en': 'hello hi thanks thank please the this that these those with you your yours our their is are was were have has how what where when why would could should english today',
  };
  final scores = <String, int>{
    for (final entry in vocabulary.entries)
      entry.key: words.intersection(entry.value.split(' ').toSet()).length,
  };
  final ranked = scores.keys.toList()
    ..sort((a, b) => scores[b]!.compareTo(scores[a]!));
  final winner = ranked.first;
  // Require two distinct cues and a clear lead, not just an accent or name.
  if (scores[winner]! >= 2 && scores[winner]! > scores[ranked[1]]! + 1) {
    return winner;
  }
  final locale = fallback.toLowerCase().split(RegExp('[-_]')).first;
  return scores.containsKey(locale) ? locale : 'en';
}

/// Bounded phrases let playback start before the entire answer is synthesized.
/// Splitting at whitespace preserves words, decimal numbers and all text.
List<String> ttsPhrases(String text, {int maxChars = 220}) {
  if (maxChars < 1) throw ArgumentError.value(maxChars, 'maxChars');
  final result = <String>[];
  for (final sentence in text.trim().split(RegExp(r'(?<=[.!?;])\s+|\n+'))) {
    var remaining = sentence.trim();
    while (remaining.length > maxChars) {
      final cut = remaining.lastIndexOf(RegExp(r'\s'), maxChars);
      if (cut <= 0) break; // Never cut a word or a surrogate pair.
      result.add(remaining.substring(0, cut));
      remaining = remaining.substring(cut).trimLeft();
    }
    if (remaining.isNotEmpty) result.add(remaining);
  }
  return result;
}
