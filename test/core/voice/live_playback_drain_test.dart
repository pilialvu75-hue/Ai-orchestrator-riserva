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
    var calls = 0;
    final drained = await waitForLivePlaybackDrain(
      isPlaying: () {
        calls++;
        return calls == 1 || calls == 4;
      },
      isCancelled: () => false,
      quietWindow: const Duration(milliseconds: 22),
      pollInterval: const Duration(milliseconds: 6),
      maxWait: const Duration(seconds: 1),
    );
    expect(drained, isTrue);
    expect(calls, greaterThanOrEqualTo(8));
  });
}
