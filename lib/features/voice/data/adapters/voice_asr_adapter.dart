abstract class VoiceAsrAdapter {
  Future<bool> initialize();

  bool get isListening;

  Future<void> startListening({
    required void Function(String text, bool isFinal) onResult,
    String localeId,
  });

  Future<void> stopListening();

  Future<void> dispose();
}
