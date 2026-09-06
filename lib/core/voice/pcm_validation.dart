import 'dart:typed_data';

/// Reject malformed output instead of converting it into apparent silence.
/// Finite zero samples are valid PCM; NaN and infinity are not.
void validatePcm(Float32List samples, int sampleRate) {
  if (sampleRate <= 0 || samples.isEmpty) {
    throw StateError('TTS returned empty audio or an invalid sample rate.');
  }
  var invalid = 0;
  for (final sample in samples) {
    if (!sample.isFinite) invalid++;
  }
  if (invalid != 0) {
    throw StateError(
      'TTS returned invalid audio: $invalid of ${samples.length} samples '
      'are non-finite.',
    );
  }
}
