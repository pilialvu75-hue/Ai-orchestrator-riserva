import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/live_playback_drain.dart';

void main() {
  test('waits for a quiet window after PCM playback stops', () async {
    var calls = 0;
    final stopwatch = Stopwatch()..start();
    final drained = await waitForLivePlaybackDrain(
      isPlaying: () => ++calls <= 4,
      isCancelled: () => false,
      quietWindow: const Duration(milliseconds: 32),
      pollInterval: const Duration(milliseconds: 8),
      maxWait: const Duration(seconds: 1),
    );
    expect(drained, isTrue);
    expect(calls, greaterThan(4));
    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(50));
  });

  test('stops waiting immediately when the Live turn is cancelled', () async {
    var cancelled = false;
    final future = waitForLivePlaybackDrain(
      isPlaying: () => true,
      isCancelled: () => cancelled,
      quietWindow: const Duration(milliseconds: 20),
      pollInterval: const Duration(milliseconds: 5),
      maxWait: const Duration(seconds: 1),
    );
    cancelled = true;
    expect(await future, isFalse);
  });

  test('never reopens microphone while audio remains active', () async {
    final drained = await waitForLivePlaybackDrain(
      isPlaying: () => true,
      isCancelled: () => false,
      quietWindow: const Duration(milliseconds: 20),
      pollInterval: const Duration(milliseconds: 5),
      maxWait: const Duration(milliseconds: 35),
    );
    expect(drained, isFalse);
  });

  test('new audio activity resets the quiet window', () async {
    const quietWindow = Duration(milliseconds: 80);
    final watch = Stopwatch()..start();
    var calls = 0;
    Duration? secondIdleStart;

    final drained = await waitForLivePlaybackDrain(
      isPlaying: () {
        calls++;
        // Start quiet, interrupt it at the very next observation, then
        // stay idle. A busy runner may skip nominal poll intervals.
        if (calls == 1 || calls == 3) return true;
        if (calls >= 4) secondIdleStart ??= watch.elapsed;
        return false;
      },
      isCancelled: () => false,
      quietWindow: quietWindow,
      pollInterval: const Duration(milliseconds: 10),
      maxWait: const Duration(seconds: 2),
    );

    expect(drained, isTrue);
    expect(secondIdleStart, isNotNull);
    // Assert the real contract rather than a scheduler-dependent poll count.
    // The production helper compares integer elapsed milliseconds, so
    // allow one millisecond of quantization in the external stopwatch.
    expect(
      watch.elapsed - secondIdleStart!,
      greaterThanOrEqualTo(quietWindow - const Duration(milliseconds: 1)),
    );
  });
}
