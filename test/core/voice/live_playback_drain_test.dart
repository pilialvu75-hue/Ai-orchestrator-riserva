import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/live_playback_drain.dart';
import 'package:ai_orchestrator/core/voice/read_aloud_transport.dart';

void main() {
  const drain = LivePlaybackDrain();

  test('allows next turn only after playback ends and a quiet tail', () async {
    var playing = true;
    Future<void>.delayed(const Duration(milliseconds: 20),
        () => playing = false);
    final clock = Stopwatch()..start();
    final safe = await drain.waitUntilQuiet(
      isPlaying: () => playing,
      isCancelled: () => false,
      quietWindow: const Duration(milliseconds: 40),
      pollInterval: const Duration(milliseconds: 10),
      timeout: const Duration(seconds: 1),
    );
    expect(safe, isTrue);
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(40));
  });

  test('fails closed if playback never drains', () async {
    final safe = await drain.waitUntilQuiet(
      isPlaying: () => true,
      isCancelled: () => false,
      pollInterval: const Duration(milliseconds: 10),
      timeout: const Duration(milliseconds: 45),
    );
    expect(safe, isFalse);
  });

  test('stop cancels waiting instead of starting a new turn', () async {
    var cancelled = false;
    Future<void>.delayed(const Duration(milliseconds: 15),
        () => cancelled = true);
    final safe = await drain.waitUntilQuiet(
      isPlaying: () => true,
      isCancelled: () => cancelled,
      pollInterval: const Duration(milliseconds: 10),
    );
    expect(safe, isFalse);
  });

  test('rejects invalid poll intervals', () {
    expect(() => drain.waitUntilQuiet(
      isPlaying: () => false,
      isCancelled: () => false,
      pollInterval: Duration.zero,
    ), throwsArgumentError);
  });
  test('native Android complete does not mean audible playback ended', () {
    const writingFinished = ReadAloudSnapshot(
      active: true,
      complete: true,
      playing: true,
      position: Duration(seconds: 2),
      buffered: Duration(seconds: 10),
    );
    expect(androidPcmPlaybackPending(writingFinished), isTrue);
    const drained = ReadAloudSnapshot(
      active: true,
      complete: true,
      position: Duration(seconds: 10),
      buffered: Duration(seconds: 10),
    );
    expect(androidPcmPlaybackPending(drained), isFalse);
  });

  test('supports asynchronous native player state polling', () async {
    var polls = 0;
    final safe = await drain.waitUntilQuiet(
      isPlaying: () async => polls++ < 2,
      isCancelled: () => false,
      quietWindow: const Duration(milliseconds: 15),
      pollInterval: const Duration(milliseconds: 5),
      timeout: const Duration(seconds: 1),
    );
    expect(safe, isTrue);
    expect(polls, greaterThanOrEqualTo(3));
  });

}
