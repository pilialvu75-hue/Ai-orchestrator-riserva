import 'dart:typed_data';

/// Represents measured PCM playback, never an estimated TTS word timer.
/// buffered is the *already generated* PCM duration; it may grow while Kokoro
/// is synthesizing later phrases.
class ReadAloudSnapshot {
  const ReadAloudSnapshot({
    this.supported = false,
    this.active = false,
    this.playing = false,
    this.paused = false,
    this.complete = false,
    this.position = Duration.zero,
    this.buffered = Duration.zero,
  });

  final bool supported;
  final bool active;
  final bool playing;
  final bool paused;
  final bool complete;
  final Duration position;
  final Duration buffered;

  factory ReadAloudSnapshot.fromMap(Map<dynamic, dynamic> data) {
    Duration readTime(String name) =>
        Duration(milliseconds: ((data[name] as num?)?.toInt() ?? 0).clamp(0, 2147483647).toInt());
    return ReadAloudSnapshot(
      supported: data['supported'] == true,
      active: data['active'] == true,
      playing: data['playing'] == true,
      paused: data['paused'] == true,
      complete: data['complete'] == true,
      position: readTime('positionMs'),
      buffered: readTime('bufferedMs'),
    );
  }
}

/// Existing (non-seekable) engines/sinks are left unmodified.
abstract interface class TtsAudioSink {
  bool get isPlaying;
  void push(Float32List samples, int sampleRate);
  void stop();
  void dispose();
}

/// Only sinks backed by a real playback clock implement this interface.
abstract interface class ReadAloudSink {
  ReadAloudSnapshot get snapshot;
  Future<void> beginReadAloud();
  Future<void> finishReadAloud();
  Future<void> stopReadAloud();
  Future<void> pauseReadAloud();
  Future<void> resumeReadAloud();
  Future<void> seekReadAloud(Duration position);
  Future<void> skipReadAloud(Duration offset);
  Future<ReadAloudSnapshot> refreshReadAloud();
}

/// Optional addition to VoiceEngine, avoiding fake pause/seek on other OSes.
abstract interface class ReadAloudVoiceEngine {
  bool get supportsRealReadAloudControls;
  ReadAloudSnapshot get readAloudSnapshot;
  Future<void> pauseReadAloud();
  Future<void> resumeReadAloud();
  Future<void> seekReadAloud(Duration position);
  Future<void> skipReadAloud(Duration offset);
  Future<ReadAloudSnapshot> refreshReadAloud();
}
