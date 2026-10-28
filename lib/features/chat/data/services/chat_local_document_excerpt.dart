/// Builds a concise, query-directed, *verbatim* evidence excerpt for a small
/// on-device context window. The entire document remains in SQLite; this only
/// controls what is submitted to the model for one question.
///
/// Never paraphrases numeric values, reconstructs missing table cells, or
/// asserts a page number unless the source has only one unique page marker.
final class ChatLocalDocumentExcerpt {
  static const int maxEvidenceChars = 950;
  static const int maxCandidateChunks = 8;
  static const int maxLines = 11;

  static final RegExp _pageMarker =
      RegExp(r'\[Pagina\s+\d+/\d+\]', caseSensitive: false);
  static final RegExp _price =
      RegExp(r'\d[\d.,]*\s*€');
  static final RegExp _itemCode =
      RegExp(r'\b[A-Z]{1,6}[-/]\d{2,}\b');
  static final RegExp _tokens =
      RegExp(r'[a-zA-Z0-9àèéìòù_]{2,}');

  static String render(
    String question,
    List<({String title, String text, int score, int timestamp})> chunks,
  ) {
    if (chunks.isEmpty) return '';

    final queryTokens = _tokenize(question);
    final normalizedQuery = question.toLowerCase();
    final tableQuestion = RegExp(
      r'prezz|quantit|q\.t|codic|cost|price|table|tabella',
    ).hasMatch(normalizedQuery);

    final lines = <_EvidenceLine>[];
    final seen = <String>{};
    final pageMarkers = <String>{};
    var ordinal = 0;

    // Preserve exact lines. The chunk overlap can repeat a line, so dedupe
    // after the first occurrence, without modifying text or prices.
    for (final chunk in chunks.take(maxCandidateChunks)) {
      for (final match in _pageMarker.allMatches(chunk.text)) {
        pageMarkers.add(match.group(0)!);
      }
      for (final raw in chunk.text.split(RegExp(r'\r?\n'))) {
        final line = raw.trim();
        if (line.isEmpty || !seen.add(chunk.title + '\u0000' + line)) continue;
        if (line.length > 500) continue;
        final overlap = _tokenize(line).intersection(queryTokens).length;
        var score = overlap * 3;
        if (tableQuestion) {
          if (_price.hasMatch(line)) score += 4;
          if (_itemCode.hasMatch(line)) score += 3;
          if (RegExp(r'ARTICOLO|Q\.TÀ|PREZZO|CODICE|TABELLA',
                  caseSensitive: false)
              .hasMatch(line)) {
            score += 2;
          }
        }
        lines.add(_EvidenceLine(
          title: chunk.title,
          text: line,
          score: score,
          ordinal: ordinal++,
        ));
      }
    }
    if (lines.isEmpty) return '';

    // Choose the most relevant lines globally, rather than prefix-truncating
    // the first chunk. This ensures table rows near the end remain accessible.
    lines.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.ordinal.compareTo(b.ordinal);
    });
    final chosen = <_EvidenceLine>[];
    var length = 0;
    for (final line in lines) {
      if (chosen.length >= maxLines) break;
      final needed = line.text.length + line.title.length + 5;
      if (length + needed > maxEvidenceChars - 95) continue;
      chosen.add(line);
      length += needed;
    }
    if (chosen.isEmpty) return '';

    // Restore source line order after relevance selection.
    chosen.sort((a, b) => a.ordinal.compareTo(b.ordinal));
    final output = StringBuffer();
    final onlyPage = pageMarkers.length == 1 ? pageMarkers.single : null;
    if (onlyPage != null) {
      output.writeln(onlyPage);
    }

    String? previousTitle;
    for (final line in chosen) {
      if (line.title != previousTitle) {
        output.writeln('[' + line.title + ']');
        previousTitle = line.title;
      }
      output.writeln(line.text);
    }
    return output.toString().trim();
  }

  static Set<String> _tokenize(String text) => _tokens
      .allMatches(text.toLowerCase())
      .map((match) => match.group(0)!)
      .toSet();
}

final class _EvidenceLine {
  const _EvidenceLine({
    required this.title,
    required this.text,
    required this.score,
    required this.ordinal,
  });
  final String title;
  final String text;
  final int score;
  final int ordinal;
}
