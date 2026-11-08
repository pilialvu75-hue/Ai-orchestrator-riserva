import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/live_echo_guard.dart';

void main() {
  test('rejects desktop transcription matching assistant speech', () {
    final guard = LiveEchoGuard();
    guard.rememberSpoken('Il tempo sarà sereno e la temperatura è mite.');
    final now = DateTime.utc(2026, 11, 8, 12);
    guard.playbackEnded(at: now);
    expect(guard.isLikelyPlaybackEcho(
      'la temperatura è mite', now: now.add(const Duration(seconds: 2))),
      isTrue);
  });

  test('normal user question is not rejected', () {
    final guard = LiveEchoGuard();
    guard.rememberSpoken('Il tempo sarà sereno.');
    final now = DateTime.utc(2026, 11, 8, 12);
    guard.playbackEnded(at: now);
    expect(guard.isLikelyPlaybackEcho(
      'Mi sai dire che giorno è oggi',
      now: now.add(const Duration(seconds: 1))), isFalse);
  });

  test('stale output and short acknowledgments are not rejected', () {
    final guard = LiveEchoGuard();
    guard.rememberSpoken('Grazie mille per la tua domanda.');
    final now = DateTime.utc(2026, 11, 8, 12);
    guard.playbackEnded(at: now);
    expect(guard.isLikelyPlaybackEcho('Grazie',
      now: now.add(const Duration(seconds: 1))), isFalse);
    expect(guard.isLikelyPlaybackEcho('Grazie mille per la tua domanda',
      now: now.add(const Duration(seconds: 21))), isFalse);
  });

  test('guard requires completed playback', () {
    final guard = LiveEchoGuard();
    guard.rememberSpoken('Una risposta già pronunciata dal sistema');
    expect(guard.isLikelyPlaybackEcho(
      'Una risposta già pronunciata dal sistema'), isFalse);
  });
}
