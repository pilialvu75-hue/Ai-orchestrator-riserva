/// Supported UI languages for voice phonetic normalization.
enum VoiceLanguage {
  italian,
  french,
  english,
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

  String normalizeForTts(String input) =>
      _applyPhonetics(_normalize(input));

  String _normalize(String input) =>
      input.replaceAll(RegExp(r'\s+'), ' ').trim();

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
