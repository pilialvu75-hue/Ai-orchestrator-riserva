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
    Object? providerName = _sentinel,
    Object? errorMessage = _sentinel,
  }) {
    return EmbeddingState(
      state: state ?? this.state,
      providerName:
          providerName == _sentinel ? this.providerName : providerName as String?,
      errorMessage: errorMessage == _sentinel
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  static const Object _sentinel = Object();

  @override
  String toString() =>
      'EmbeddingState(state: $state, providerName: $providerName, '
      'errorMessage: $errorMessage)';
}
