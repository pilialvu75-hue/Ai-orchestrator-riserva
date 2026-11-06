import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/live_voice_latency.dart';

void main() {
  test('milestones emit once and do not expose audio or transcripts', () {
    final latency = LiveVoiceLatency();
    final tokenMs = latency.recordFirstTokenMs();
    final requestMs = latency.recordFirstTtsRequestMs();
    expect(tokenMs, isNotNull);
    expect(requestMs, isNotNull);
    expect(tokenMs!, greaterThanOrEqualTo(0));
    expect(requestMs!, greaterThanOrEqualTo(tokenMs));
    expect(latency.recordFirstTokenMs(), isNull);
    expect(latency.recordFirstTtsRequestMs(), isNull);
  });

  test('first TTS milestone can be recorded with no preceding token', () {
    final latency = LiveVoiceLatency();
    expect(latency.recordFirstTtsRequestMs(), isNotNull);
    expect(latency.recordFirstTtsRequestMs(), isNull);
  });
}
