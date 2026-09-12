import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('native token budget contract', () {
    test('CMake builds the token-budget bridge entrypoint', () {
      final cmake = File('native/android/CMakeLists.txt').readAsStringSync();

      expect(
        cmake,
        contains('add_library(llama_bridge SHARED llama_bridge_entrypoint.cpp)'),
      );
    });

    test('native bridge exposes exact session token counting', () {
      final header = File('native/android/llama_bridge.h').readAsStringSync();
      final entrypoint =
          File('native/android/llama_bridge_entrypoint.cpp').readAsStringSync();

      expect(header, contains('llb_session_token_count'));
      expect(entrypoint, contains('llb_session_token_count'));
      expect(entrypoint, contains('llama_tokenize('));
      expect(entrypoint, contains('true,\n        true'));
      expect(entrypoint, contains('[TOKEN_COUNT_EXACT]'));
    });

    test('start generation enforces prompt plus generation within nCtx', () {
      final entrypoint =
          File('native/android/llama_bridge_entrypoint.cpp').readAsStringSync();

      expect(entrypoint, contains('kPromptTokenSafetyMargin'));
      expect(entrypoint, contains('prompt_tokens'));
      expect(entrypoint, contains('generation_capacity'));
      expect(entrypoint, contains('n_ctx - prompt_tokens - kPromptTokenSafetyMargin'));
      expect(entrypoint, contains('effective_max_tokens'));
      expect(entrypoint, contains('std::min(max_tokens, generation_capacity)'));
      expect(entrypoint, contains('[TOKEN_BUDGET_NATIVE]'));
      expect(entrypoint, contains('llb_session_start_gen_unbudgeted'));
    });

    test('Dart FFI contract requires the exact token count symbol', () {
      final nativeTypes = File(
        'lib/core/runtime/inference/ffi/llama_native_types.dart',
      ).readAsStringSync();
      final bindings = File(
        'lib/core/runtime/inference/ffi/llama_bindings.dart',
      ).readAsStringSync();
      final loader = File(
        'lib/core/runtime/inference/ffi/llama_ffi_loader.dart',
      ).readAsStringSync();

      expect(nativeTypes, contains('LlbSessionTokenCountNative'));
      expect(bindings, contains("'llb_session_token_count'"));
      expect(bindings, contains('int countTokens(int sessionId, String text)'));
      expect(loader, contains('llb_session_token_count'));
    });

    test('Dart and native prompt safety margins stay aligned', () {
      final nativeTypes = File(
        'lib/core/runtime/inference/ffi/llama_native_types.dart',
      ).readAsStringSync();
      final entrypoint =
          File('native/android/llama_bridge_entrypoint.cpp').readAsStringSync();

      expect(nativeTypes, contains('promptTokenSafetyMargin = 32'));
      expect(entrypoint, contains('kPromptTokenSafetyMargin = 32'));
    });
  });
}
