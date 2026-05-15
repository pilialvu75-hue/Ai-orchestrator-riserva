import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/tokenizer/tokenizer_state.dart';

class TokenizerRuntime {
  static const List<int> _ggufMagic = [0x47, 0x47, 0x55, 0x46];

  TokenizerState _state = const TokenizerState();

  final StreamController<TokenizerState> _streamController =
      StreamController<TokenizerState>.broadcast();

  Stream<TokenizerState> get stateStream => _streamController.stream;

  TokenizerState get currentState => _state;

  bool get isReady => _state.isReady;

  void _emit(TokenizerState newState) {
    _state = newState;
    _streamController.add(newState);
  }

  Future<bool> initialize(String modelPath) async {
    _emit(_state.copyWith(state: TokenizerLifecycleState.initializing));

    if (modelPath.isEmpty) {
      const reason = 'modelPath must not be empty';
      debugPrint('[TOKENIZER_READY] FAIL – $reason');
      _emit(TokenizerState(
        state: TokenizerLifecycleState.failed,
        errorMessage: reason,
      ));
      return false;
    }

    final file = File(modelPath);
    if (!file.existsSync()) {
      final reason = 'Model file not found: $modelPath';
      debugPrint('[TOKENIZER_READY] FAIL – $reason');
      _emit(TokenizerState(
        state: TokenizerLifecycleState.failed,
        modelPath: modelPath,
        errorMessage: reason,
      ));
      return false;
    }

    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final header = await raf.read(4);

      if (header.length < 4) {
        const reason = 'Model file too small to contain GGUF header';
        debugPrint('[TOKENIZER_READY] FAIL – $reason');
        _emit(TokenizerState(
          state: TokenizerLifecycleState.failed,
          modelPath: modelPath,
          errorMessage: reason,
        ));
        return false;
      }

      for (int i = 0; i < 4; i++) {
        if (header[i] != _ggufMagic[i]) {
          const reason = 'Invalid GGUF magic bytes — not a valid model file';
          debugPrint('[TOKENIZER_READY] FAIL – $reason');
          _emit(TokenizerState(
            state: TokenizerLifecycleState.failed,
            modelPath: modelPath,
            errorMessage: reason,
          ));
          return false;
        }
      }
    } catch (e) {
      final reason = 'Cannot read model file: $e';
      debugPrint('[TOKENIZER_READY] FAIL – $reason');
      _emit(TokenizerState(
        state: TokenizerLifecycleState.failed,
        modelPath: modelPath,
        errorMessage: reason,
      ));
      return false;
    } finally {
      await raf?.close();
    }

    debugPrint('[TOKENIZER_READY] OK – tokenizer ready for model: $modelPath');
    _emit(TokenizerState(
      state: TokenizerLifecycleState.ready,
      modelPath: modelPath,
    ));
    return true;
  }

  void reset() {
    debugPrint('[TOKENIZER_READY] Reset – returning to uninitialized');
    _emit(const TokenizerState());
  }
}
