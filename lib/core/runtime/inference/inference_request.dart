import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

/// Optional caller directive for the runtime boundary.
///
/// [runtimeDefault] preserves the persisted Local/Cloud/Hybrid setting.
/// [localOnly] and [cloudOnly] are explicit decisions made by a higher layer.
/// In Hybrid mode the Orchestrator can therefore make the decision itself,
/// while explicit Cloud chat can bypass the Orchestrator entirely.
enum InferenceRouteDirective {
  runtimeDefault,
  localOnly,
  cloudOnly,
}

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
    this.requestId,
    this.projectId,
    this.taskId,
    this.executionId,
    this.checkpointId,
    this.routeDirective = InferenceRouteDirective.runtimeDefault,
    this.cloudProviderId,
    this.allowCloudProviderFailover = true,
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

  /// Optional cross-layer identities used by the Workshop/Cantiere.
  ///
  /// Request, project, task, session, execution and checkpoint are distinct
  /// concepts. Local runtime may ignore these fields; Cloud orchestration can
  /// use them for tracing and deterministic resume without polluting prompts.
  final String? requestId;
  final String? projectId;
  final String? taskId;
  final String? executionId;
  final String? checkpointId;

  /// Explicit routing decision from the caller.
  final InferenceRouteDirective routeDirective;

  /// Concrete Cloud provider selected by the higher-level Orchestrator.
  ///
  /// Null means the independent Cloud router is allowed to select the best
  /// provider for the task. A non-null value is an explicit provider binding,
  /// typically produced by Hybrid orchestration.
  final String? cloudProviderId;

  /// Whether the Cloud runtime may switch provider inside the same request.
  ///
  /// Explicit Cloud chat keeps this true so quota/rate-limit failover is
  /// automatic. Hybrid orchestration normally sets it false because Hannibal
  /// owns provider replacement and checkpoint/resume decisions.
  final bool allowCloudProviderFailover;

  static int maxTokensForModel(String? modelId) {
    final id = (modelId ?? '').toLowerCase();

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
    String? requestId,
    String? projectId,
    String? taskId,
    String? executionId,
    String? checkpointId,
    InferenceRouteDirective? routeDirective,
    String? cloudProviderId,
    bool? allowCloudProviderFailover,
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
      requestId: requestId ?? this.requestId,
      projectId: projectId ?? this.projectId,
      taskId: taskId ?? this.taskId,
      executionId: executionId ?? this.executionId,
      checkpointId: checkpointId ?? this.checkpointId,
      routeDirective: routeDirective ?? this.routeDirective,
      cloudProviderId: cloudProviderId ?? this.cloudProviderId,
      allowCloudProviderFailover:
          allowCloudProviderFailover ?? this.allowCloudProviderFailover,
    );
  }

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
