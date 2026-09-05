import 'package:ai_orchestrator/features/cloud_ai/domain/entities/ai_request.dart';

/// Data-layer model for an AI request, with provider serialization helpers.
///
/// The model remains provider-neutral until this boundary: conversation
/// history is kept structured and translated only when building the native
/// payload expected by each provider.
class AiRequestModel extends AiRequest {
  const AiRequestModel({
    required super.prompt,
    super.systemPrompt,
    super.temperature,
    super.maxTokens,
    super.messages,
    super.tools,
    super.modelId,
    super.providerId,
    super.taskType,
    super.metadata,
  });

  factory AiRequestModel.fromEntity(AiRequest entity) {
    return AiRequestModel(
      prompt: entity.prompt,
      systemPrompt: entity.systemPrompt,
      temperature: entity.temperature,
      maxTokens: entity.maxTokens,
      messages: entity.messages,
      tools: entity.tools,
      modelId: entity.modelId,
      providerId: entity.providerId,
      taskType: entity.taskType,
      metadata: entity.metadata,
    );
  }

  /// System instructions from both the explicit system prompt and any
  /// provider-neutral system turns. Providers that expose a dedicated system
  /// field can use this value directly.
  String? get combinedSystemPrompt {
    final parts = <String>[
      if (systemPrompt?.trim().isNotEmpty ?? false) systemPrompt!.trim(),
      ...messages
          .where((message) => message.role == AiMessageRole.system)
          .map((message) => message.content.trim())
          .where((content) => content.isNotEmpty),
    ];

    if (parts.isEmpty) {
      return null;
    }

    return parts.join('\n\n');
  }

  /// Converts this request to an OpenAI-compatible Chat Completions payload.
  Map<String, dynamic> toOpenAiJson({String? model}) {
    final resolvedModel = _resolveModel(model, fallback: 'gpt-4o');

    return <String, dynamic>{
      'model': resolvedModel,
      'temperature': temperature,
      'max_tokens': maxTokens,
      if (tools.isNotEmpty) 'tools': tools,
      'messages': <Map<String, String>>[
        if (combinedSystemPrompt case final system?)
          <String, String>{'role': 'system', 'content': system},
        ...messages
            .where((message) => message.role != AiMessageRole.system)
            .map(_toOpenAiMessage),
        <String, String>{'role': 'user', 'content': prompt},
      ],
    };
  }

  /// Converts this request to the Google Gemini generateContent payload.
  Map<String, dynamic> toGeminiJson() {
    return <String, dynamic>{
      'contents': <Map<String, dynamic>>[
        ...messages
            .where((message) => message.role != AiMessageRole.system)
            .map(_toGeminiContent),
        <String, dynamic>{
          'role': 'user',
          'parts': <Map<String, String>>[
            <String, String>{'text': prompt},
          ],
        },
      ],
      'generationConfig': <String, dynamic>{
        'temperature': temperature,
        'maxOutputTokens': maxTokens,
      },
      if (tools.isNotEmpty)
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{'functionDeclarations': tools},
        ],
      if (combinedSystemPrompt case final system?)
        'systemInstruction': <String, dynamic>{
          'parts': <Map<String, String>>[
            <String, String>{'text': system},
          ],
        },
    };
  }

  /// Claude/Anthropic conversation payload. System instructions are excluded
  /// because Anthropic transports them through its dedicated `system` field.
  List<Map<String, String>> toClaudeMessages() {
    return <Map<String, String>>[
      ...messages
          .where((message) => message.role != AiMessageRole.system)
          .map(
            (message) => <String, String>{
              'role': message.role == AiMessageRole.assistant
                  ? 'assistant'
                  : 'user',
              'content': message.content,
            },
          ),
      <String, String>{'role': 'user', 'content': prompt},
    ];
  }

  String _resolveModel(String? model, {required String fallback}) {
    final explicit = model?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }

    final requested = modelId?.trim();
    if (requested != null && requested.isNotEmpty) {
      return requested;
    }

    return fallback;
  }

  Map<String, String> _toOpenAiMessage(AiMessage message) {
    return <String, String>{
      'role': message.role == AiMessageRole.assistant ? 'assistant' : 'user',
      'content': message.content,
    };
  }

  Map<String, dynamic> _toGeminiContent(AiMessage message) {
    return <String, dynamic>{
      'role': message.role == AiMessageRole.assistant ? 'model' : 'user',
      'parts': <Map<String, String>>[
        <String, String>{'text': message.content},
      ],
    };
  }
}
