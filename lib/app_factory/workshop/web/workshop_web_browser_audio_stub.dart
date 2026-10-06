/// Native-safe fallback for the Aivexus Web audio adapter.
///
/// Native platforms keep using their own voice stack. This stub only exists so
/// shared builds never import browser-only Dart libraries.
final class WorkshopWebBrowserAudio {
  bool get isListening => false;
  bool get canDictate => false;
  bool get canSpeak => false;

  Future<bool> startDictation({
    required void Function(String text, bool isFinal) onResult,
    void Function(bool listening)? onStateChanged,
    void Function(String message)? onError,
  }) async {
    onStateChanged?.call(false);
    onError?.call('La dettatura vocale è disponibile solo nel browser Web.');
    return false;
  }

  Future<void> stopDictation() async {}

  void speak(String text) {}

  void stopSpeaking() {}
}
