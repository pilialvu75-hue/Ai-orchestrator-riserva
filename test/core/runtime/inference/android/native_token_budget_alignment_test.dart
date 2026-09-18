import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dart prompt safety margin matches native hard guard', () {
    final nativeSource =
        File('native/android/llama_bridge_entrypoint.cpp').readAsStringSync();

    expect(
      nativeSource,
      contains(
        'constexpr int32_t kPromptTokenSafetyMargin = '
        '${LlamaNativeDefaults.promptTokenSafetyMargin};',
      ),
    );
  });
}
