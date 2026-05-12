import 'package:ai_orchestrator/features/cloud_ai/domain/entities/ai_request.dart';

/// Data-layer model for an AI request, with serialisation helpers.
class AiRequestModel extends AiRequest {
  const AiRequestModel({
    required super.prompt,
    super.systemPrompt,
    super.temperature,
    super.maxTokens,
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
      if (systemPrompt != null && systemPrompt!.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt}
          ]
        },
    };
  }
}
