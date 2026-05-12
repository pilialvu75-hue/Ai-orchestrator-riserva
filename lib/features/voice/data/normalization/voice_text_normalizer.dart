class VoiceTextNormalizer {
  const VoiceTextNormalizer();

  String normalizeAsr(String input) => _normalize(input);

  String normalizeForTts(String input) => _normalize(input);

  String _normalize(String input) => input.replaceAll(RegExp(r'\s+'), ' ').trim();
}
