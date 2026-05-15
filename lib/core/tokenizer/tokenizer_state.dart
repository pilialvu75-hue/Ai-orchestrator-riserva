import 'package:flutter/foundation.dart';

enum TokenizerLifecycleState { uninitialized, initializing, ready, failed }

@immutable
class TokenizerState {
  const TokenizerState({
    this.state = TokenizerLifecycleState.uninitialized,
    this.modelPath,
    this.errorMessage,
  });

  final TokenizerLifecycleState state;
  final String? modelPath;
  final String? errorMessage;

  bool get isReady => state == TokenizerLifecycleState.ready;

  TokenizerState copyWith({
    TokenizerLifecycleState? state,
    String? modelPath,
    String? errorMessage,
  }) {
    return TokenizerState(
      state: state ?? this.state,
      modelPath: modelPath ?? this.modelPath,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  String toString() =>
      'TokenizerState(state: $state, modelPath: $modelPath, errorMessage: $errorMessage)';
}
