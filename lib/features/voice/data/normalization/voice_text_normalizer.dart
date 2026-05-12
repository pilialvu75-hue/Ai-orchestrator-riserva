class VoiceTextNormalizer {
  const VoiceTextNormalizer();

  String normalizeAsr(String input) {
    return input.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String normalizeForTts(String input) {
    return input.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
