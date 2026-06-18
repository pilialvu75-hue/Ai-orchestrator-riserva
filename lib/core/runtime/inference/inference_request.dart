import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

class InferenceRequest {
  static const int defaultMaxTokens = 512;
  static const double defaultTemperature = 0.45;

  const InferenceRequest({
    required this.sessionId,
    required this.prompt,
    this.systemPrompt,
    this.context = const [],
    this.isOffline = false,
    this.maxTokens = defaultMaxTokens,
    this.temperature = defaultTemperature,
    this.topP = 0.9,
    this.repeatPenalty = 1.1,
    this.modelId,
    this.modelPath,
  });

  final String sessionId;
  final String prompt;
  final String? systemPrompt;
  final List<ChatTurn> context;
  final bool isOffline;
  final int maxTokens;
  final double temperature;
  final double topP;
  final double repeatPenalty;
  final String? modelId;
  final String? modelPath;

  static int maxTokensForModel(String? modelId) {
    final id = (modelId ?? '').toLowerCase();
    if (id.contains('14b') || id.contains('13b') || id.contains('12b')) return 2048;
    if (id.contains('7b') || id.contains('8b')) return 1024;
    if (id.contains('phi3_5') || id.contains('phi-3.5') || id.contains('phi3.5')) {
      return 768;
    }
    if (id.contains('3b') || id.contains('4b') || id.contains('3.8b')) return 768;
    return 512;
  }

  static double temperatureForModel(String? modelId) {
    final id = (modelId ?? '').toLowerCase();
    if (id.contains('14b') || id.contains('7b') || id.contains('8b')) return 0.6;
    if (id.contains('phi3_5') || id.contains('phi-3.5') || id.contains('phi3.5')) {
      return 0.5;
    }
    if (id.contains('3b') || id.contains('4b') || id.contains('3.8b')) return 0.5;
    return 0.4;
  }

  InferenceRequest copyWith({
    String? sessionId,
    String? prompt,
    String? systemPrompt,
    List<ChatTurn>? context,
    bool? isOffline,
    int? maxTokens,
    double? temperature,
    double? topP,
    double? repeatPenalty,
    String? modelId,
    String? modelPath,
  }) {
    return InferenceRequest(
      sessionId: sessionId ?? this.sessionId,
      prompt: prompt ?? this.prompt,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      context: List.unmodifiable(context ?? this.context),
      isOffline: isOffline ?? this.isOffline,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      repeatPenalty: repeatPenalty ?? this.repeatPenalty,
      modelId: modelId ?? this.modelId,
      modelPath: modelPath ?? this.modelPath,
    );
  }
}
