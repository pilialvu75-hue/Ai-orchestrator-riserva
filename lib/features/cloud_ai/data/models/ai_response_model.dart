import 'package:ai_orchestrator/features/cloud_ai/domain/entities/ai_response.dart';

/// Data-layer model for an AI response.
class AiResponseModel extends AiResponse {
  const AiResponseModel({
    required super.text,
    required super.model,
    required super.tokensUsed,
    required super.timestamp,
  });

  factory AiResponseModel.fromOpenAiJson(Map<String, dynamic> json) {
    final choice = (json['choices'] as List<dynamic>).first
        as Map<String, dynamic>;
    final message =
        choice['message'] as Map<String, dynamic>? ?? {};
    final usage = json['usage'] as Map<String, dynamic>? ?? {};

    return AiResponseModel(
      text: message['content'] as String? ?? '',
      model: json['model'] as String? ?? 'unknown',
      tokensUsed: usage['total_tokens'] as int? ?? 0,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory AiResponseModel.fromGeminiJson(Map<String, dynamic> json) {
    final candidates =
        json['candidates'] as List<dynamic>? ?? [];
    String text = '';
    if (candidates.isNotEmpty) {
      final content =
          (candidates.first as Map<String, dynamic>)['content']
              as Map<String, dynamic>? ?? {};
      final parts = content['parts'] as List<dynamic>? ?? [];
      if (parts.isNotEmpty) {
        text = (parts.first as Map<String, dynamic>)['text'] as String? ?? '';
      }
    }

    final usageMeta =
        json['usageMetadata'] as Map<String, dynamic>? ?? {};
    final tokens = (usageMeta['totalTokenCount'] as int?) ?? 0;

    return AiResponseModel(
      text: text,
      model: json['modelVersion'] as String? ?? 'gemini',
      tokensUsed: tokens,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
