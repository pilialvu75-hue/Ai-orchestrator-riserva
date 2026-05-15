import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/tokenizer/tokenizer_runtime.dart';

class TokenizerValidator {
  Future<bool> isTokenizerReady(TokenizerRuntime runtime) async {
    final ready = runtime.isReady;
    if (ready) {
      debugPrint('[TOKENIZER_READY] OK – tokenizer runtime is ready');
    } else {
      debugPrint(
        '[TOKENIZER_READY] FAIL – tokenizer runtime is not ready '
        '(state: ${runtime.currentState.state})',
      );
    }
    return ready;
  }

  Future<bool> validateForModel(
    TokenizerRuntime runtime,
    String modelPath,
  ) async {
    if (!runtime.isReady) {
      debugPrint(
        '[TOKENIZER_READY] FAIL – runtime not ready, cannot validate model',
      );
      return false;
    }

    final currentModelPath = runtime.currentState.modelPath;
    if (currentModelPath != modelPath) {
      debugPrint(
        '[TOKENIZER_READY] FAIL – model path mismatch: '
        'expected "$modelPath", got "$currentModelPath"',
      );
      return false;
    }

    debugPrint('[TOKENIZER_READY] OK – model path matches: $modelPath');
    return true;
  }
}
