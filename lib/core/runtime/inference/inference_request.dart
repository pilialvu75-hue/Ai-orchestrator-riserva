import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

class InferenceRequest {
  const InferenceRequest({
    required this.sessionId,
    required this.prompt,
    this.systemPrompt,
    this.context = const [],
    this.isOffline = false,
    this.maxTokens = 512,        // ← era 256, ora 512 default sicuro
    this.temperature = 0.45,     // ← era 0.7, ora 0.45 per coerenza su 1B
    this.topP = 0.9,             // ← nuovo: nucleus sampling
    this.repeatPenalty = 1.1,    // ← nuovo: riduce ripetizioni
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

  /// Calcola maxTokens ottimale in base alla dimensione del modello.
  /// Chiamato dall'Orchestrator quando non si vuole hardcodare il valore.
  static int maxTokensForModel(String? modelId) {
    final id = (modelId ?? '').toLowerCase();
    if (id.contains('14b') || id.contains('13b') || id.contains('12b')) {
      return 2048;
    }
    if (id.contains('7b') || id.contains('8b')) {
      return 1024;
    }
    if (id.contains('3b') || id.contains('4b') || id.contains('3.8b')) {
      return 768;
    }
    // 1B, 1.5B, tiny → 512 è sicuro su Android senza OOM
    return 512;
  }

  /// Temperature ottimale per dimensione modello.
  static double temperatureForModel(String? modelId) {
    final id = (modelId ?? '').toLowerCase();
    if (id.contains('14b') || id.contains('7b') || id.contains('8b')) {
      return 0.6;
    }
    // Modelli piccoli: temperatura bassa per coerenza
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
