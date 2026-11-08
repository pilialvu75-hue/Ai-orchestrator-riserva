import 'dart:async';

/// Waits until an output sink has been quiet long enough to reopen the mic.
///
/// Playback can outlive a TTS generation Future because PCM is queued in a
/// native sink. The quiet window covers a small amount of native audio
/// buffering and acoustic tail after a sink reports idle. This is NOT AEC.
Future<bool> waitForLivePlaybackDrain({
  required FutureOr<bool> Function() isPlaying,
  required bool Function() isCancelled,
  Duration maxWait = const Duration(seconds: 90),
  Duration quietWindow = const Duration(milliseconds: 1100),
  Duration pollInterval = const Duration(milliseconds: 100),
}) async {
  if (maxWait <= Duration.zero ||
      quietWindow <= Duration.zero ||
      pollInterval <= Duration.zero) {
    throw ArgumentError('Invalid Live playback drain timing.');
  }

  final watch = Stopwatch()..start();
  int? quietFromMs;

  while (watch.elapsed < maxWait) {
    if (isCancelled()) return false;
    final active = await isPlaying();
    if (isCancelled()) return false;

    if (active) {
      quietFromMs = null;
    } else {
      quietFromMs ??= watch.elapsedMilliseconds;
      if (watch.elapsedMilliseconds - quietFromMs >=
          quietWindow.inMilliseconds) {
        return true;
      }
    }

    await Future<void>.delayed(pollInterval);
  }

  return false;
}
