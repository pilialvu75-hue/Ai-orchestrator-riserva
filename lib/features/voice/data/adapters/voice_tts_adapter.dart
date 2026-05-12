abstract class VoiceTtsAdapter {
  Future<bool> initialize();

  bool get isSpeaking;

  Future<void> speak(String text);

  Future<void> stopSpeaking();

  Future<void> dispose();
}
