import 'package:ai_orchestrator/features/cloud_ai/domain/entities/ai_request.dart';

/// Data-layer model for an AI request, with serialisation helpers.
class AiRequestModel extends AiRequest {
  /// Lista delle definizioni dei tool (JSON Schema) che il modello può invocare.
  final List<Map<String, dynamic>>? tools;

  const AiRequestModel({
    required super.prompt,
    super.systemPrompt,
    super.temperature,
    super.maxTokens,
    this.tools,
  });

  factory AiRequestModel.fromEntity(AiRequest entity) {
    return AiRequestModel(
      prompt: entity.prompt,
      systemPrompt: entity.systemPrompt,
      temperature: entity.temperature,
      maxTokens: entity.maxTokens,
    );
  }

  /// Converts this request to the JSON body expected by the OpenAI Chat API.
  Map<String, dynamic> toOpenAiJson({String model = 'gpt-4o'}) {
    return {
      'model': model,
      'temperature': temperature,
      'max_tokens': maxTokens,
      // OpenAI accetta i tool direttamente come array di oggetti
      if (tools != null && tools!.isNotEmpty) 'tools': tools,
      'messages': [
        if (systemPrompt != null && systemPrompt!.isNotEmpty)
          {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': prompt},
      ],
    };
  }

  /// Converts this request to the JSON body expected by the Gemini API.
  Map<String, dynamic> toGeminiJson() {
    return {
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': temperature,
        'maxOutputTokens': maxTokens,
      },
      // Gemini richiede il wrapper 'functionDeclarations' dentro 'tools'
      if (tools != null && tools!.isNotEmpty)
        'tools': [
          {'functionDeclarations': tools}
        ],
      if (systemPrompt != null && systemPrompt!.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt}
          ]
        },
    };
  }
}
