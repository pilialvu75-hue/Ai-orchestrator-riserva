import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _readNormalizedText(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}

void main() {
  group('native token budget contract', () {
    test('CMake builds the token-budget bridge entrypoint', () {
      final cmake = _readNormalizedText('native/android/CMakeLists.txt');

      expect(
        cmake,
        contains('add_library(llama_bridge SHARED llama_bridge_entrypoint.cpp)'),
      );
    });

    test('native bridge exposes exact session token counting', () {
      final header = _readNormalizedText('native/android/llama_bridge.h');
      final entrypoint =
          _readNormalizedText('native/android/llama_bridge_entrypoint.cpp');

      expect(header, contains('llb_session_token_count'));
      expect(entrypoint, contains('llb_session_token_count'));
      expect(entrypoint, contains('llama_tokenize('));
      expect(entrypoint, contains('true,\n        true'));
      expect(entrypoint, contains('[TOKEN_COUNT_EXACT]'));
    });

    test('start generation enforces prompt plus generation within nCtx', () {
      final entrypoint =
          _readNormalizedText('native/android/llama_bridge_entrypoint.cpp');

      expect(entrypoint, contains('kPromptTokenSafetyMargin'));
      expect(entrypoint, contains('prompt_tokens'));
      expect(entrypoint, contains('generation_capacity'));
      expect(entrypoint, contains('n_ctx - prompt_tokens - kPromptTokenSafetyMargin'));
      expect(entrypoint, contains('effective_max_tokens'));
      expect(entrypoint, contains('std::min(max_tokens, generation_capacity)'));
      expect(entrypoint, contains('[TOKEN_BUDGET_NATIVE]'));
      expect(entrypoint, contains('llb_session_start_gen_unbudgeted'));
    });

    test('scoped generation reuses only verified KV prefixes', () {
      final header = _readNormalizedText('native/android/llama_bridge.h');
      final bridge = _readNormalizedText('native/android/llama_bridge.cpp');
      final entrypoint =
          _readNormalizedText('native/android/llama_bridge_entrypoint.cpp');

      expect(header, contains('llb_session_start_gen_scoped'));
      expect(bridge, contains('prompt_cache_scope'));
      expect(bridge, contains('cache_snapshot.scope != cache_scope'));
      expect(bridge, contains('exact_prompt_regeneration'));
      expect(bridge, contains('llama_memory_seq_rm(memory, 0, reused_tokens, -1)'));
      expect(bridge, contains('llama_memory_clear(memory, true)'));
      expect(bridge, contains('[KV_CACHE_REUSE]'));
      expect(bridge, contains('reused_tokens'));
      expect(bridge, contains('prefilled_tokens'));
      expect(entrypoint, contains('llb_session_start_gen_scoped_unbudgeted'));
    });

    test('Dart FFI contract requires the exact token count symbol', () {
      final nativeTypes = _readNormalizedText(
        'lib/core/runtime/inference/ffi/llama_native_types.dart',
      );
      final bindings = _readNormalizedText(
        'lib/core/runtime/inference/ffi/llama_bindings.dart',
      );
      final loader = _readNormalizedText(
        'lib/core/runtime/inference/ffi/llama_ffi_loader.dart',
      );

      expect(nativeTypes, contains('LlbSessionTokenCountNative'));
      expect(bindings, contains("'llb_session_token_count'"));
      expect(bindings, contains('int countTokens(int sessionId, String text)'));
      expect(loader, contains('llb_session_token_count'));
    });
  });
}
