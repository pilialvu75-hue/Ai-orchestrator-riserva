import 'package:ai_orchestrator/core/runtime/inference/prompt_turn.dart';

class InferenceRequest {
  const InferenceRequest({
    required this.sessionId,
    required this.prompt,
    this.systemPrompt,
    this.context = const <String>[],
    this.contextTurns = const <PromptTurn>[],
    this.recalledContext = const <String>[],
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
  final List<PromptTurn> contextTurns;
  final List<String> recalledContext;
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
    List<PromptTurn>? contextTurns,
    List<String>? recalledContext,
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
      context: context ?? this.context,
      contextTurns: contextTurns ?? this.contextTurns,
      recalledContext: recalledContext ?? this.recalledContext,
      isOffline: isOffline ?? this.isOffline,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
      modelId: modelId ?? this.modelId,
      modelPath: modelPath ?? this.modelPath,
    );
  }
}
