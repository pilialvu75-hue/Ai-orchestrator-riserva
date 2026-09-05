import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

class InferenceRequest {
  static bool _hasModelSize(String id, String size) =>
      RegExp('(?:^|[^0-9.])${RegExp.escape(size)}' r'(?:$|[^0-9a-z])')
          .hasMatch(id);

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

  /// Restituisce il limite di token predefinito in base alla taglia
  /// del modello.
  ///
  /// IMPORTANTE:
  ///
  /// La taglia del modello NON determina:
  /// - la famiglia LLM;
  /// - il chat template;
  /// - la piattaforma supportata;
  /// - il ruolo dell'agente.
  ///
  /// Queste responsabilità appartengono ai rispettivi livelli
  /// dell'architettura.
  ///
  /// La funzione serve solamente a evitare fallback troppo bassi
  /// quando introduciamo modelli più grandi in futuro.
  static int maxTokensForModel(String? modelId) {
    final id = (modelId ?? '').toLowerCase();

    // -------------------------------------------------------------------------
    // Modelli molto grandi
    // -------------------------------------------------------------------------

    if (_hasModelSize(id, '70b') ||
        _hasModelSize(id, '72b') ||
        _hasModelSize(id, '65b')) {
      return 4096;
    }

    if (_hasModelSize(id, '32b') ||
        _hasModelSize(id, '30b') ||
        _hasModelSize(id, '34b') ||
        _hasModelSize(id, '27b')) {
      return 3072;
    }

    // -------------------------------------------------------------------------
    // Modelli medio-grandi
    // -------------------------------------------------------------------------

    if (_hasModelSize(id, '14b') ||
        _hasModelSize(id, '13b') ||
        _hasModelSize(id, '12b')) {
      return 2048;
    }

    if (_hasModelSize(id, '9b') ||
        _hasModelSize(id, '8b') ||
        _hasModelSize(id, '7b')) {
      return 1024;
    }

    // -------------------------------------------------------------------------
    // Modelli piccoli / mobile
    // -------------------------------------------------------------------------

    if (id.contains('phi3_5') ||
        id.contains('phi-3.5') ||
        id.contains('phi3.5')) {
      return 1024;
    }

    if (_hasModelSize(id, '4b') ||
        _hasModelSize(id, '3.8b') ||
        _hasModelSize(id, '3b')) {
      return 768;
    }

    if (_hasModelSize(id, '2b') ||
        _hasModelSize(id, '1.8b') ||
        _hasModelSize(id, '1.7b') ||
        _hasModelSize(id, '1.5b') ||
        _hasModelSize(id, '1b')) {
      return 512;
    }

    return defaultMaxTokens;
  }

  /// Temperatura base associata alla taglia/famiglia del modello.
  ///
  /// Manteniamo volutamente valori conservativi.
  /// Il runtime può sovrascrivere questi valori tramite le proprie
  /// impostazioni di sampling.
  static double temperatureForModel(String? modelId) {
    final id = (modelId ?? '').toLowerCase();

    if (_hasModelSize(id, '70b') ||
        _hasModelSize(id, '72b') ||
        _hasModelSize(id, '65b') ||
        _hasModelSize(id, '32b') ||
        _hasModelSize(id, '30b') ||
        _hasModelSize(id, '34b') ||
        _hasModelSize(id, '27b') ||
        _hasModelSize(id, '14b') ||
        _hasModelSize(id, '13b') ||
        _hasModelSize(id, '12b') ||
        _hasModelSize(id, '9b') ||
        _hasModelSize(id, '8b') ||
        _hasModelSize(id, '7b')) {
      return 0.6;
    }

    if (id.contains('phi3_5') ||
        id.contains('phi-3.5') ||
        id.contains('phi3.5')) {
      return 0.5;
    }

    if (_hasModelSize(id, '4b') ||
        _hasModelSize(id, '3.8b') ||
        _hasModelSize(id, '3b')) {
      return 0.5;
    }

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

  /// Mappa la richiesta in formato JSON o lista di messaggi per l'engine LLM.
  List<Map<String, String>> toMessageList() {
    final List<Map<String, String>> messages = [];

    if (systemPrompt != null && systemPrompt!.isNotEmpty) {
      messages.add({
        'role': 'system',
        'content': systemPrompt!,
      });
    }

    for (final turn in context) {
      messages.add({
        'role': turn.role.name,
        'content': turn.content,
      });
    }

    messages.add({
      'role': 'user',
      'content': prompt,
    });

    return messages;
  }
}
