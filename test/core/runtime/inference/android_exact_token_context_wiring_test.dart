import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Android exact context wiring', () {
    test('startup passes the active RuntimeSession token counter explicitly', () {
      final startup = _read(
        'lib/core/runtime/inference/android/streaming/'
        'android_ffi_runtime_provider_generation_startup.part.dart',
      );

      expect(
        startup,
        contains('bindings.countTokens(nativeSessionId, prompt)'),
      );
      expect(startup, contains('requestedGenerationTokens:'));
      expect(startup, contains('exactTokenCounter:'));
    });

    test('prompt composer uses exact selector without global session state', () {
      final isolator = _read(
        'lib/core/runtime/inference/android/helpers/'
        'android_ffi_runtime_provider_session_state_isolator.part.dart',
      );
      final bindings = _read(
        'lib/core/runtime/inference/ffi/llama_bindings.dart',
      );

      expect(isolator, contains('NativeTokenContextBudget.select('));
      expect(isolator, contains('LlamaNativeDefaults.promptTokenSafetyMargin'));
      expect(isolator, contains('[CONTEXT_TOKEN_BUDGET]'));
      expect(bindings, isNot(contains('countTokensForCurrentSession')));
      expect(bindings, isNot(contains('_currentBudgetSessionId')));
    });

    test('Dart safety margin stays aligned with native bridge', () {
      final nativeTypes = _read(
        'lib/core/runtime/inference/ffi/llama_native_types.dart',
      );
      final nativeBridge = _read('native/android/llama_bridge_entrypoint.cpp');

      expect(
        nativeTypes,
        contains('static const int promptTokenSafetyMargin = 32;'),
      );
      expect(
        nativeBridge,
        contains('constexpr int32_t kPromptTokenSafetyMargin = 32;'),
      );
    });
  });
}
