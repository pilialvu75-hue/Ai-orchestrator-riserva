import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Llama runtime defaults configure GPU layers for Android sessions', () {
    expect(LlamaNativeDefaults.nGpuLayers, 99);
  });
}
