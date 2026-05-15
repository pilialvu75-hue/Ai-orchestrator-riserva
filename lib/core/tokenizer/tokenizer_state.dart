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
    Object? modelPath = _sentinel,
    Object? errorMessage = _sentinel,
  }) {
    return TokenizerState(
      state: state ?? this.state,
      modelPath: modelPath == _sentinel ? this.modelPath : modelPath as String?,
      errorMessage: errorMessage == _sentinel
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  static const Object _sentinel = Object();

  @override
  String toString() =>
      'TokenizerState(state: $state, modelPath: $modelPath, errorMessage: $errorMessage)';
}
