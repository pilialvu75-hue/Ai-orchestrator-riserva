final class WorkshopProjectTitleDeriver {
  const WorkshopProjectTitleDeriver._();

  static const int _maxTitleLength = 48;

  static const List<String> _nameMarkers = <String>[
    'chiamata ',
    'chiamato ',
    'called ',
    'named ',
    'llamada ',
    'llamado ',
    'nommée ',
    'nommé ',
    'appelee ',
    'appelée ',
    'appele ',
    'appelé ',
  ];

  static const List<String> _wordTerminators = <String>[
    ' che ',
    ' con ',
    ' mostra ',
    ' visualizza ',
    ' deve ',
    ' dovrà ',
    ' dovra ',
    ' with ',
    ' that ',
    ' which ',
    ' shows ',
    ' show ',
    ' que ',
    ' y ',
    ' avec ',
    ' qui ',
    ' et ',
  ];

  /// Derives a short stable UI title from the owner's request without asking
  /// the model to rename the project.
  ///
  /// An explicitly named app wins ("chiamata Contatore Test", "called Notes").
  /// Otherwise the historical bounded prompt summary remains the fallback.
  static String derive(String? instruction) {
    final raw = instruction?.trim() ?? '';
    if (raw.isEmpty) return 'Nuova produzione Cantiere';

    final normalized = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final explicit = _explicitName(normalized);
    if (explicit != null && explicit.isNotEmpty) {
      return _bounded(explicit);
    }

    return _bounded(normalized);
  }

  static String? _explicitName(String normalized) {
    final lower = normalized.toLowerCase();

    for (final marker in _nameMarkers) {
      final index = lower.indexOf(marker);
      if (index < 0) continue;

      var candidate = normalized.substring(index + marker.length).trimLeft();
      candidate = _stripLeadingQuote(candidate);
      if (candidate.isEmpty) continue;

      var end = candidate.length;
      for (final punctuation in <String>['.', ',', ';', ':', '\n']) {
        final punctuationIndex = candidate.indexOf(punctuation);
        if (punctuationIndex >= 0 && punctuationIndex < end) {
          end = punctuationIndex;
        }
      }

      final candidateLower = candidate.toLowerCase();
      for (final terminator in _wordTerminators) {
        final terminatorIndex = candidateLower.indexOf(terminator);
        if (terminatorIndex >= 0 && terminatorIndex < end) {
          end = terminatorIndex;
        }
      }

      for (final quote in <String>['"', '”', '»', "'"]) {
        final quoteIndex = candidate.indexOf(quote);
        if (quoteIndex >= 0 && quoteIndex < end) {
          end = quoteIndex;
        }
      }

      candidate = candidate.substring(0, end).trim();
      candidate = candidate.replaceAll(
        RegExp(r'''^[\s"'“”«»]+|[\s"'“”«»]+$'''),
        '',
      );
      if (candidate.isNotEmpty) return candidate;
    }

    return null;
  }

  static String _stripLeadingQuote(String value) {
    if (value.isEmpty) return value;
    const quotes = <String>['"', "'", '“', '«'];
    return quotes.contains(value.substring(0, 1))
        ? value.substring(1).trimLeft()
        : value;
  }

  static String _bounded(String value) {
    final normalized = value.trim();
    if (normalized.length <= _maxTitleLength) return normalized;
    return '${normalized.substring(0, _maxTitleLength - 3)}...';
  }
}
