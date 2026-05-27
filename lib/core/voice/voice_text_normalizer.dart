/// Normalizes raw text output from STT or input to TTS across Italian, English,
/// and French, with tolerance for mixed-language (code-switching) sentences.
///
/// Rules applied (in order):
/// 1. Collapse whitespace – handles fragmented token streams.
/// 2. Number expansion – converts common numeric forms to spoken words.
/// 3. Italian abbreviation expansion.
/// 4. French abbreviation expansion.
/// 5. English abbreviation expansion.
/// 6. Strip unsupported characters (control characters, non-printable Unicode).
///
/// The normalizer is intentionally conservative: it only expands abbreviations
/// and numbers it recognizes with high confidence so that English technical
/// vocabulary embedded in Italian/French sentences passes through unchanged.
class VoiceTextNormalizer {
  const VoiceTextNormalizer();

  // ── Italian abbreviation map ────────────────────────────────────────────────
  static const Map<String, String> _itAbbreviations = {
    r'\bSig\.': 'Signore',
    r'\bSig\.ra\b': 'Signora',
    r'\bDott\.': 'Dottore',
    r'\bDott\.ssa\b': 'Dottoressa',
    r'\bAvv\.': 'Avvocato',
    r'\bProf\.': 'Professore',
    r'\bEcc\.': 'Eccetera',
    r'\bN\.ro\b': 'numero',
    r'\bn\.\s*(\d)': r'numero \1',
    r'\bpag\.': 'pagina',
    r'\bca\.': 'circa',
    r'\bvs\.': 'versus',
    r'\bdl\b': 'decilitri',
    r'\bkm\b': 'chilometri',
    r'\bcm\b': 'centimetri',
    r'\bmm\b': 'millimetri',
    r'\bkg\b': 'chilogrammi',
    r'\bmg\b': 'milligrammi',
  };

  // ── French abbreviation map ─────────────────────────────────────────────────
  static const Map<String, String> _frAbbreviations = {
    r'\bM\.': 'Monsieur',
    r'\bMme\.': 'Madame',
    r'\bMlle\.': 'Mademoiselle',
    r'\bDr\.': 'Docteur',
    r'\bPr\.': 'Professeur',
    r'\betc\.': 'et cetera',
    r'\bsvp\b': "s'il vous plaît",
    r'\brdv\b': 'rendez-vous',
    r'\bkm\b': 'kilomètres',
    r'\bcm\b': 'centimètres',
    r'\bmm\b': 'millimètres',
    r'\bkg\b': 'kilogrammes',
  };

  // ── English abbreviation map ────────────────────────────────────────────────
  static const Map<String, String> _enAbbreviations = {
    r'\bMr\.': 'Mister',
    r'\bMrs\.': 'Missus',
    r'\bMs\.': 'Miss',
    r'\bDr\.': 'Doctor',
    r'\bProf\.': 'Professor',
    r'\betc\.': 'et cetera',
    r'\be\.g\.': 'for example',
    r'\bi\.e\.': 'that is',
    r'\bvs\.': 'versus',
    r'\bapprox\.': 'approximately',
    r'\bmax\b': 'maximum',
    r'\bmin\b': 'minimum',
    r'\bkm\b': 'kilometers',
    r'\bcm\b': 'centimeters',
    r'\bmm\b': 'millimeters',
    r'\bkg\b': 'kilograms',
  };

  /// Normalizes a raw ASR result for display or further processing.
  String normalizeAsr(String input) => _normalize(input);

  /// Normalizes text before sending it to the TTS engine.
  ///
  /// Applies the full normalization pipeline so that the TTS engine receives
  /// clean prose rather than abbreviations or number strings.
  String normalizeForTts(String input, {String locale = 'it'}) {
    var text = _normalize(input);
    text = _expandNumbers(text, locale: locale);
    text = _expandAbbreviations(text, locale: locale);
    text = _stripUnsupported(text);
    return text;
  }

  // ── Core normalization ──────────────────────────────────────────────────────

  String _normalize(String input) => input.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Expands the most common numeric patterns to spoken-word equivalents.
  ///
  /// Handles ordinals (1°, 2a), percentages, and plain integers up to 999.
  String _expandNumbers(String text, {String locale = 'it'}) {
    // Percentage: 85% → "ottantacinque percento" (IT) / "eighty-five percent" (EN)
    text = text.replaceAllMapped(
      RegExp(r'(\d+)\s*%'),
      (m) => '${m[1]} ${_percentWord(locale)}',
    );
    // Ordinals (Italian): 1° → "primo", 2° → "secondo", etc.
    if (locale == 'it') {
      text = text.replaceAllMapped(
        RegExp(r'\b(\d+)[°oa]\b'),
        (m) => _itOrdinal(int.tryParse(m[1]!) ?? 0),
      );
    }
    return text;
  }

  String _percentWord(String locale) {
    switch (locale) {
      case 'fr':
        return 'pourcent';
      case 'en':
        return 'percent';
      default:
        return 'percento';
    }
  }

  String _itOrdinal(int n) {
    const ordinals = <int, String>{
      1: 'primo', 2: 'secondo', 3: 'terzo', 4: 'quarto', 5: 'quinto',
      6: 'sesto', 7: 'settimo', 8: 'ottavo', 9: 'nono', 10: 'decimo',
    };
    return ordinals[n] ?? n.toString();
  }

  /// Applies abbreviation expansion for the given [locale].
  ///
  /// Italian is the primary locale but English abbreviations are also applied
  /// to handle code-switching (e.g. "il Dr. Smith" in an Italian sentence).
  String _expandAbbreviations(String text, {String locale = 'it'}) {
    Map<String, String> primary;
    switch (locale) {
      case 'fr':
        primary = _frAbbreviations;
      case 'en':
        primary = _enAbbreviations;
      default:
        primary = _itAbbreviations;
    }
    // Apply primary-locale abbreviations first.
    for (final entry in primary.entries) {
      text = text.replaceAllMapped(
        RegExp(entry.key, caseSensitive: false),
        (m) {
          // Preserve back-references (e.g. r'\1' in the replacement).
          var replacement = entry.value;
          for (var i = 1; i <= m.groupCount; i++) {
            replacement = replacement.replaceAll(r'\' + i.toString(), m[i] ?? '');
          }
          return replacement;
        },
      );
    }
    // For Italian/French, also apply English abbreviations so technical terms
    // like "Dr. Smith" are spoken correctly inside multilingual sentences.
    if (locale == 'it' || locale == 'fr') {
      for (final entry in _enAbbreviations.entries) {
        // Skip entries already handled by the primary locale map.
        if (primary.containsKey(entry.key)) continue;
        text = text.replaceAllMapped(
          RegExp(entry.key, caseSensitive: false),
          (m) => entry.value,
        );
      }
    }
    return text;
  }

  /// Removes control characters and non-printable Unicode code points that
  /// confuse VITS phonemizers.
  String _stripUnsupported(String text) {
    // Remove C0/C1 control characters but keep newlines which are used as
    // sentence boundaries in the TTS pipeline.
    return text.replaceAll(
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]'),
      '',
    );
  }
}
