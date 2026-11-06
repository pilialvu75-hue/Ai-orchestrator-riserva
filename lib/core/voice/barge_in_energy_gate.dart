import 'dart:math' as math;
import 'dart:typed_data';

/// Conservative energy gate for a future Live barge-in pipeline.
///
/// This is NOT speech recognition, voice identification, or echo cancellation.
/// Callers must supply microphone PCM that has already passed a separately
/// validated echo-suppression and speech activity detector stages. Until
/// both exist and are verified, pass false for their confirmations; the
/// gate will never request interruption.
class BargeInEnergyGate {
  BargeInEnergyGate({
    this.sampleRate = 16000,
    this.minimumRms = 0.035,
    this.requiredActiveMs = 120,
  }) {
    if (sampleRate <= 0 || minimumRms <= 0 || requiredActiveMs <= 0) {
      throw ArgumentError('Invalid barge-in energy gate configuration.');
    }
  }

  final int sampleRate;
  final double minimumRms;
  final int requiredActiveMs;

  int _activeSamples = 0;
  bool _triggered = false;

  void reset() {
    _activeSamples = 0;
    _triggered = false;
  }

  /// Returns true only once per continuous burst of sufficiently loud audio.
  ///
  /// [echoSuppressed] must mean that AEC/echo rejection was verified by the
  /// audio pipeline, not merely enabled in platform settings.
  /// [speechConfirmed] must be supplied by a real voice-activity detector:
  /// energy alone cannot distinguish speech from music, taps or loud noise.
  bool process(
    Float32List samples, {
    required bool assistantSpeaking,
    required bool echoSuppressed,
    required bool speechConfirmed,
  }) {
    if (!assistantSpeaking || !echoSuppressed || !speechConfirmed ||
        samples.isEmpty) {
      reset();
      return false;
    }

    var sumSquares = 0.0;
    for (final sample in samples) {
      if (!sample.isFinite || sample.abs() > 1.0) {
        reset();
        return false;
      }
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / samples.length);
    if (rms < minimumRms) {
      reset();
      return false;
    }

    _activeSamples += samples.length;
    final requiredSamples = (sampleRate * requiredActiveMs / 1000).ceil();
    if (_triggered || _activeSamples < requiredSamples) {
      return false;
    }

    _triggered = true;
    return true;
  }
}
