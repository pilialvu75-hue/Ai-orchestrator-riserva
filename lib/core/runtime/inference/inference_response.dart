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
  });

  final String text;
  final String? model;
  final int tokensGenerated;
  final int timestamp;
  final bool isFinal;
  final bool isError;
  final String? errorMessage;
  final String? runtimeNotice;

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
    );
  }

  factory InferenceResponse.error(String message) {
    return InferenceResponse(
      text: '',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isFinal: true,
      isError: true,
      errorMessage: message,
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
