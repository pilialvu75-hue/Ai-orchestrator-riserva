/// Event and phase models used by the Android FFI runtime provider.
enum FfiPhase {
  idle,
  sessionCreating,
  generationStarting,
  promptIngestion,
  streamingTokens,
  terminating,
}

enum RuntimePhase {
  tokenizing,
  startingGeneration,
  waitingFirstToken,
  streaming,
  completed,
  failed,
  cancelled,
  stalled,
}

abstract final class RuntimeEventNames {
  static const String dartStreamReceive = 'DART_STREAM_RECEIVE';
  static const String dartTokenReceived = 'DART_TOKEN_RECEIVED';
  static const String tokenEmit = 'TOKEN_EMIT';
  static const String dartStreamRender = 'DART_STREAM_RENDER';
}
