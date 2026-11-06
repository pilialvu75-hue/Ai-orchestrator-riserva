/// Monotonic milestones within one Live request.
///
/// This tracks timings, not speech contents. TTS dispatch is NOT audible
/// first-sample latency: actual playback latency needs an audio-sink callback.
class LiveVoiceLatency {
  LiveVoiceLatency({Stopwatch? stopwatch})
      : _clock = stopwatch ?? (Stopwatch()..start()) {
    if (!_clock.isRunning) _clock.start();
  }

  final Stopwatch _clock;
  bool _firstTokenSeen = false;
  bool _ttsRequested = false;

  int? recordFirstTokenMs() {
    if (_firstTokenSeen) return null;
    _firstTokenSeen = true;
    return _clock.elapsedMilliseconds;
  }

  int? recordFirstTtsRequestMs() {
    if (_ttsRequested) return null;
    _ttsRequested = true;
    return _clock.elapsedMilliseconds;
  }
}
