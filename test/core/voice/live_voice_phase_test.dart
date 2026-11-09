import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/live_voice_phase.dart';

void main() {
  test('reports stage durations separately from total elapsed time', () {
    var now = 0;
    final timeline = LiveVoicePhaseTimeline(elapsedMs: () => now);
    expect(timeline.phase, LiveVoicePhase.idle);
    now = 20;
    final listening = timeline.transitionTo(LiveVoicePhase.listening)!;
    expect(listening.previous, LiveVoicePhase.idle);
    expect(listening.current, LiveVoicePhase.listening);
    expect(listening.stageMs, 20);
    expect(listening.totalMs, 20);

    now = 75;
    final inference = timeline.transitionTo(LiveVoicePhase.thinking)!;
    expect(inference.previous, LiveVoicePhase.listening);
    expect(inference.stageMs, 55);
    expect(inference.totalMs, 75);

    now = 90;
    final synthesis = timeline.transitionTo(LiveVoicePhase.synthesizing)!;
    expect(synthesis.stageMs, 15);
    expect(synthesis.totalMs, 90);
  });

  test('ignores a repeated phase and tolerates a nonmonotonic fake clock', () {
    var now = 1;
    final timeline = LiveVoicePhaseTimeline(elapsedMs: () => now);
    expect(timeline.transitionTo(LiveVoicePhase.idle), isNull);
    now = 5;
    timeline.transitionTo(LiveVoicePhase.listening);
    expect(timeline.transitionTo(LiveVoicePhase.listening), isNull);
    now = 2;
    final next = timeline.transitionTo(LiveVoicePhase.playing)!;
    expect(next.stageMs, 0);
    expect(next.totalMs, 1);
  });

  test('records preparation, model resolution, playback and idle', () {
    var now = 0;
    final timeline = LiveVoicePhaseTimeline(elapsedMs: () => now);
    for (final phase in <LiveVoicePhase>[
      LiveVoicePhase.preparing,
      LiveVoicePhase.listening,
      LiveVoicePhase.resolvingModel,
      LiveVoicePhase.thinking,
      LiveVoicePhase.synthesizing,
      LiveVoicePhase.playing,
      LiveVoicePhase.idle,
    ]) {
      now += 10;
      expect(timeline.transitionTo(phase)?.current, phase);
    }
    expect(timeline.phase, LiveVoicePhase.idle);
  });
}
