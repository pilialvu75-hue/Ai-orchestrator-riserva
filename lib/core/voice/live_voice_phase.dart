/// The actual stage of one Live request, independent of the audio widget's
/// coarse isSpeaking/isListening flags.
enum LiveVoicePhase {
  idle,
  preparing,
  listening,
  resolvingModel,
  thinking,
  synthesizing,
  playing,
}

/// Timing for the stage that has just finished. Contains no audio/transcript.
class LiveVoicePhaseTiming {
  const LiveVoicePhaseTiming({
    required this.previous,
    required this.current,
    required this.stageMs,
    required this.totalMs,
  });

  final LiveVoicePhase previous;
  final LiveVoicePhase current;
  final int stageMs;
  final int totalMs;
}

/// Monotonic phase timing without voice content in diagnostics.
/// An injected time source keeps unit tests independent from wall-clock timing.
class LiveVoicePhaseTimeline {
  LiveVoicePhaseTimeline({int Function()? elapsedMs})
      : _elapsedMs = elapsedMs ?? _startMonotonicClock() {
    _startedAtMs = _elapsedMs();
    _phaseStartedAtMs = _startedAtMs;
  }

  static int Function() _startMonotonicClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsedMilliseconds;
  }

  final int Function() _elapsedMs;
  late final int _startedAtMs;
  late int _phaseStartedAtMs;
  LiveVoicePhase _phase = LiveVoicePhase.idle;

  LiveVoicePhase get phase => _phase;

  LiveVoicePhaseTiming? transitionTo(LiveVoicePhase next) {
    if (next == _phase) return null;
    final now = _elapsedMs();
    final previous = _phase;
    final result = LiveVoicePhaseTiming(
      previous: previous,
      current: next,
      stageMs: (now - _phaseStartedAtMs).clamp(0, 1 << 30),
      totalMs: (now - _startedAtMs).clamp(0, 1 << 30),
    );
    _phase = next;
    _phaseStartedAtMs = now;
    return result;
  }
}
