/// Hard terminal states that every inference request MUST end in.
///
/// Consumers MUST check [InferenceResponse.terminalState] when
/// [InferenceResponse.isFinal] is `true` to distinguish success from failure
/// instead of relying solely on the boolean [InferenceResponse.isError].
enum InferenceTerminalState {
  /// Inference completed normally and a response was produced.
  success,

  /// Inference was stopped because a time limit was exceeded.
  timeout,

  /// Inference failed due to a runtime or network error.
  failed,

  /// Inference was cancelled by the caller.
  cancelled,

  /// No validated local model is available and cloud providers are unreachable.
  modelUnavailable,
}

class InferenceResponse {
  const InferenceResponse({
    required this.text,
    required this.timestamp,
    this.model,
    this.tokensGenerated = 0,
    this.isFinal = false,
    this.isError = false,
    this.errorMessage,
    this.runtimeNotice,
    this.terminalState,
  });

  final String text;
  final String? model;
  final int tokensGenerated;
  final int timestamp;
  final bool isFinal;
  final bool isError;
  final String? errorMessage;
  final String? runtimeNotice;

  /// Set on every response where [isFinal] is `true`.
  ///
  /// `null` on intermediate token chunks and runtime-notice chunks.
  final InferenceTerminalState? terminalState;

  factory InferenceResponse.token({
    required String text,
    String? model,
  }) {
    return InferenceResponse(
      text: text,
      model: model,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory InferenceResponse.finalChunk({
    required String text,
    required int tokensGenerated,
    String? model,
  }) {
    return InferenceResponse(
      text: text,
      model: model,
      tokensGenerated: tokensGenerated,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isFinal: true,
      terminalState: InferenceTerminalState.success,
    );
  }

  /// Creates a terminal error response.
  ///
  /// [state] defaults to [InferenceTerminalState.failed]; callers may supply a
  /// more specific value (e.g. [InferenceTerminalState.cancelled] or
  /// [InferenceTerminalState.timeout]).
  factory InferenceResponse.error(
    String message, {
    InferenceTerminalState state = InferenceTerminalState.failed,
  }) {
    return InferenceResponse(
      text: '',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isFinal: true,
      isError: true,
      errorMessage: message,
      terminalState: state,
    );
  }

  factory InferenceResponse.notice(String message) {
    return InferenceResponse(
      text: '',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isFinal: false,
      runtimeNotice: message,
    );
  }
}
