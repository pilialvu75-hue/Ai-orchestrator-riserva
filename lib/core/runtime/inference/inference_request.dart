import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

class InferenceRequest {
  const InferenceRequest({
    required this.sessionId,
    required this.prompt,
    this.systemPrompt,
    this.context = const <ChatTurn>[],
    this.isOffline = false,
    this.maxTokens = 256,
    this.temperature = 0.7,
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
  final String? modelId;
  final String? modelPath;

  InferenceRequest copyWith({
    String? sessionId,
    String? prompt,
    String? systemPrompt,
    List<ChatTurn>? context,
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
      context: List<ChatTurn>.unmodifiable(context ?? this.context),
      isOffline: isOffline ?? this.isOffline,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
      modelId: modelId ?? this.modelId,
      modelPath: modelPath ?? this.modelPath,
    );
  }
}
