/// Optional PCM lifecycle contract for streamed Live speech.
///
/// A normal read-aloud tap is its own seekable playback timeline. In Live,
/// many separate speak() calls may belong to ONE assistant answer.
/// Resetting Android PCM between these chunks truncates the preceding speech.
/// The manager explicitly opens and closes each Live response instead.
abstract interface class LiveSpeechSequenceEngine {
  void beginLiveSpeechSequence();

  /// End successfully only after all TTS chunks were enqueued. On failure,
  /// discard the partial audio timeline and never reopen the microphone.
  Future<void> endLiveSpeechSequence({required bool completed});
}
