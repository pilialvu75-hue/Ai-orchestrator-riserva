import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/pcm_validation.dart';

void main() {
  test('accepts finite signal and genuine silence', () {
    validatePcm(Float32List.fromList([-0.5, 0, 0.5]), 24000);
    validatePcm(Float32List(32), 24000);
  });

  for (final value in [double.nan, double.infinity, double.negativeInfinity]) {
    test('rejects non-finite PCM ($value), including mixed output', () {
      expect(
        () => validatePcm(Float32List.fromList([0, value, 0.5]), 24000),
        throwsStateError,
      );
    });
  }

  test('rejects the all-invalid device output', () {
    expect(
      () => validatePcm(
        Float32List.fromList(List<double>.filled(85800, double.nan)),
        24000,
      ),
      throwsStateError,
    );
  });

  test('rejects missing samples and invalid sample rates', () {
    expect(() => validatePcm(Float32List(0), 24000), throwsStateError);
    expect(() => validatePcm(Float32List(1), 0), throwsStateError);
    expect(() => validatePcm(Float32List(1), -1), throwsStateError);
  });
}
