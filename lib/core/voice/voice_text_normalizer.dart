/// Supported UI languages for voice phonetic normalization.
enum VoiceLanguage {
  italian,
  french,
  english,
}

enum VoiceExpressiveStyle {
  neutral,
  happy,
  serious,
  sad,
}

class TtsNormalizationResult {
  const TtsNormalizationResult({
    required this.text,
    required this.style,
  });

  final String text;
  final VoiceExpressiveStyle style;
}

/// Pre-processing utility that normalises text before sending it to the TTS
/// engine.
///
/// When [language] is [VoiceLanguage.italian] or [VoiceLanguage.french],
/// common English tech terms are converted to their phonetically adapted
/// equivalents so that the offline TTS model pronounces them naturally.
/// For [VoiceLanguage.english] no phonetic substitution is applied.
///
/// The [language] property can be updated at runtime so that the live-voice
/// settings panel can switch languages without rebuilding the DI graph.
class VoiceTextNormalizer {
  VoiceTextNormalizer({this.language = VoiceLanguage.italian});

  VoiceLanguage language;

  String normalizeAsr(String input) => _normalize(input);

  String normalizeForTts(String input) => preprocessForTts(input).text;

  TtsNormalizationResult preprocessForTts(String input) {
    final normalized = _normalize(input);
    final style = _extractStyle(normalized);
    final cleanText = normalized
        .replaceAll(RegExp(r'\[(FELICE|SERIO|TRISTE)\]', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return TtsNormalizationResult(
      text: _applyPhonetics(cleanText),
      style: style,
    );
  }

  String _normalize(String input) =>
      input.replaceAll(RegExp(r'\s+'), ' ').trim();

  VoiceExpressiveStyle _extractStyle(String text) {
    if (RegExp(r'\[FELICE\]', caseSensitive: false).hasMatch(text)) {
      return VoiceExpressiveStyle.happy;
    }
    if (RegExp(r'\[TRISTE\]', caseSensitive: false).hasMatch(text)) {
      return VoiceExpressiveStyle.sad;
    }
    if (RegExp(r'\[SERIO\]', caseSensitive: false).hasMatch(text)) {
      return VoiceExpressiveStyle.serious;
    }
    return VoiceExpressiveStyle.neutral;
  }

  String _applyPhonetics(String text) {
    switch (language) {
      case VoiceLanguage.italian:
        return _applyItalian(text);
      case VoiceLanguage.french:
        return _applyFrench(text);
      case VoiceLanguage.english:
        return text;
    }
  }

  // ── Italian phonetic substitutions ──────────────────────────────────────

  static const Map<String, String> _italianTerms = {
    'pull request': 'pul ricuest',
    'merge': 'merg',
    'build': 'bild',
    'deploy': 'diploi',
    'branch': 'branc',
    'push': 'pus',
    'debug': 'dibag',
    'stack': 'stek',
    'backend': 'bechend',
    'framework': 'freimwork',
    'pipeline': 'paiplayn',
    'token': 'token',
    'timeout': 'taimaout',
  };

  static String _applyItalian(String text) {
    var result = text;
    for (final entry in _italianTerms.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    return result;
  }

  // ── French phonetic substitutions ───────────────────────────────────────

  static const Map<String, String> _frenchTerms = {
    'pull request': 'poul requête',
    'code': 'cod',
    'bug': 'bøg',
    'merge': 'mèrj',
    'build': 'bild',
    'deploy': 'déploie',
    'branch': 'branche',
    'commit': 'comit',
    'debug': 'débogue',
    'stack': 'stak',
    'pipeline': 'pipeline',
    'timeout': 'time-aout',
  };

  static String _applyFrench(String text) {
    var result = text;
    for (final entry in _frenchTerms.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    return result;
  }
}
