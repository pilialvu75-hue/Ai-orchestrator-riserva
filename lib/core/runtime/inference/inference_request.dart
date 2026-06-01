class InferenceRequest {
  const InferenceRequest({
    required this.sessionId,
    required this.prompt,
    this.systemPrompt,
    this.context = const <String>[],
    this.isOffline = false,
    this.maxTokens = 256,
    this.temperature = 0.7,
    this.modelId,
    this.modelPath,
  });

  final String sessionId;
  final String prompt;
  final String? systemPrompt;
  final List<String> context;
  final bool isOffline;
  final int maxTokens;
  final double temperature;
  final String? modelId;
  final String? modelPath;

  InferenceRequest copyWith({
    String? sessionId,
    String? prompt,
    String? systemPrompt,
    List<String>? context,
    bool? isOffline,
    int? maxTokens,
    double? temperature,
    String? modelId,
    String? modelPath,
  }) {
    return InferenceRequest(
      sessionId: sessionId ?? this.sessionId,
      prompt: prompt ?? this.prompt,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      context: List<String>.unmodifiable(context ?? this.context),
      isOffline: isOffline ?? this.isOffline,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
      modelId: modelId ?? this.modelId,
      modelPath: modelPath ?? this.modelPath,
    );
  }
}
