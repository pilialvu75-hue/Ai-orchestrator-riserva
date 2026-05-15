import 'package:flutter/foundation.dart';

enum EmbeddingLifecycleState { uninitialized, initializing, ready, failed }

@immutable
class EmbeddingState {
  const EmbeddingState({
    this.state = EmbeddingLifecycleState.uninitialized,
    this.providerName,
    this.errorMessage,
  });

  final EmbeddingLifecycleState state;
  final String? providerName;
  final String? errorMessage;

  bool get isReady => state == EmbeddingLifecycleState.ready;

  EmbeddingState copyWith({
    EmbeddingLifecycleState? state,
    String? providerName,
    String? errorMessage,
  }) {
    return EmbeddingState(
      state: state ?? this.state,
      providerName: providerName ?? this.providerName,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  String toString() =>
      'EmbeddingState(state: $state, providerName: $providerName, '
      'errorMessage: $errorMessage)';
}
