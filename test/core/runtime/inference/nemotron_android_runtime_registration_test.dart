import 'package:ai_orchestrator/core/runtime/inference/android/models/android_ffi_runtime_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Nemotron 3 Nano 4B keeps the canonical manifest runtime id', () {
    expect(
      LocalInferenceModelIds.nemotron3Nano4b,
      'nemotron3_nano_4b',
    );
  });

  test('Nemotron 3 Nano 4B is quarantined from validated Android FFI models', () {
    expect(
      AndroidFfiRuntimeModelIds.validatedModelIds,
      isNot(contains(LocalInferenceModelIds.nemotron3Nano4b)),
    );
  });
}
