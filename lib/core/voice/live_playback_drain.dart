import 'dart:async';

/// Prevents a new microphone turn from starting before native playback has
/// actually drained. TTS generation completion is not playback completion.
///
/// A quiet tail protects desktop microphone capture from device output
/// buffering and room reverberation. This is NOT full acoustic echo
/// cancellation and cannot guarantee rejection of every speaker echo.
class LivePlaybackDrain {
  const LivePlaybackDrain();

  Future<bool> waitUntilQuiet({
    required bool Function() isPlaying,
    required bool Function() isCancelled,
    Duration quietWindow = const Duration(milliseconds: 1200),
    Duration pollInterval = const Duration(milliseconds: 80),
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (quietWindow.isNegative || pollInterval <= Duration.zero ||
        timeout <= Duration.zero) {
      throw ArgumentError('Invalid playback drain durations.');
    }
    final watch = Stopwatch()..start();
    Duration? quietSince;
    while (true) {
      if (isCancelled()) return false;
      final elapsed = watch.elapsed;
      if (isPlaying()) {
        quietSince = null;
      } else {
        quietSince ??= elapsed;
        if (elapsed - quietSince >= quietWindow) return true;
      }
      if (elapsed >= timeout) return false;
      await Future<void>.delayed(pollInterval);
    }
  }
}
