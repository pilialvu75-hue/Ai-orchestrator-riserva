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
    final choices = json['choices'] as List<dynamic>? ?? const <dynamic>[];
    final firstChoice = choices.isNotEmpty && choices.first is Map
        ? Map<String, dynamic>.from(choices.first as Map)
        : const <String, dynamic>{};
    final rawMessage = firstChoice['message'];
    final message = rawMessage is Map
        ? Map<String, dynamic>.from(rawMessage)
        : const <String, dynamic>{};
    final usage = json['usage'] is Map
        ? Map<String, dynamic>.from(json['usage'] as Map)
        : const <String, dynamic>{};

    return AiResponseModel(
      text: _extractOpenAiContent(message['content']),
      model: json['model'] as String? ?? 'unknown',
      tokensUsed: _readInt(usage['total_tokens']),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory AiResponseModel.fromGeminiJson(Map<String, dynamic> json) {
    final candidates = json['candidates'] as List<dynamic>? ?? const <dynamic>[];
    final textParts = <String>[];

    if (candidates.isNotEmpty && candidates.first is Map) {
      final candidate = Map<String, dynamic>.from(candidates.first as Map);
      final rawContent = candidate['content'];
      if (rawContent is Map) {
        final content = Map<String, dynamic>.from(rawContent);
        final parts = content['parts'] as List<dynamic>? ?? const <dynamic>[];
        for (final rawPart in parts) {
          if (rawPart is! Map) continue;
          final part = Map<String, dynamic>.from(rawPart);
          final text = part['text'];
          if (text is String && text.isNotEmpty) {
            textParts.add(text);
          }
        }
      }
    }

    final usageMeta = json['usageMetadata'] is Map
        ? Map<String, dynamic>.from(json['usageMetadata'] as Map)
        : const <String, dynamic>{};

    return AiResponseModel(
      text: textParts.join('\n').trim(),
      model: json['modelVersion'] as String? ?? 'gemini',
      tokensUsed: _readInt(usageMeta['totalTokenCount']),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static String _extractOpenAiContent(Object? content) {
    if (content is String) {
      return content;
    }

    if (content is List) {
      final parts = <String>[];
      for (final rawPart in content) {
        if (rawPart is! Map) continue;
        final part = Map<String, dynamic>.from(rawPart);
        final text = part['text'];
        if (text is String && text.isNotEmpty) {
          parts.add(text);
        }
      }
      return parts.join('\n').trim();
    }

    return '';
  }

  static int _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }
}
