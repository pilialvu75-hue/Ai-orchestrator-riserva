import 'package:equatable/equatable.dart';

enum AiMessageRole {
  system,
  user,
  assistant,
}

/// Provider-neutral conversational message.
///
/// Provider adapters convert this representation to their native request
/// format at the final data-source boundary. Keeping history structured here
/// prevents Cloud runtime from flattening a conversation into a single prompt.
class AiMessage extends Equatable {
  const AiMessage({
    required this.role,
    required this.content,
  });

  final AiMessageRole role;
  final String content;

  @override
  List<Object?> get props => <Object?>[role, content];
}

/// Domain entity representing a request to an AI model.
///
/// This is the canonical provider-neutral contract shared by orchestration and
/// Cloud provider implementations. Provider/model selection can be attached to
/// a request without leaking provider-specific JSON into upper layers.
class AiRequest extends Equatable {
  const AiRequest({
    required this.prompt,
    this.systemPrompt,
    this.temperature = 0.7,
    this.maxTokens = 2048,
    this.messages = const <AiMessage>[],
    this.tools = const <Map<String, dynamic>>[],
    this.modelId,
    this.providerId,
    this.taskType,
    this.metadata = const <String, dynamic>{},
  });

  final String prompt;
  final String? systemPrompt;
  final double temperature;
  final int maxTokens;

  /// Conversation history before [prompt].
  final List<AiMessage> messages;

  /// Provider-neutral function/tool declarations.
  final List<Map<String, dynamic>> tools;

  /// Concrete model selected for this request, when routing has already made
  /// that decision. A provider adapter may use its own safe default when null.
  final String? modelId;

  /// Provider selected for this request, when known.
  final String? providerId;

  /// Normalized task category (for example: general, coding, reasoning).
  final String? taskType;

  /// Non-secret execution metadata. Secrets must never be placed here.
  final Map<String, dynamic> metadata;

  @override
  List<Object?> get props => <Object?>[
        prompt,
        systemPrompt,
        temperature,
        maxTokens,
        messages,
        tools,
        modelId,
        providerId,
        taskType,
        metadata,
      ];
}
