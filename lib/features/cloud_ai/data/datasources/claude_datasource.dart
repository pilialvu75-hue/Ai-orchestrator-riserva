import 'dart:convert';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_response_model.dart';
import 'package:http/http.dart' as http;

class ClaudeDataSource {
  ClaudeDataSource({
    required this.apiKey,
    http.Client? httpClient,
    this.model = 'claude-3-5-sonnet-latest',
  }) : _client = httpClient ?? http.Client();

  final String apiKey;
  final String model;
  final http.Client _client;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<AiResponseModel> complete(AiRequestModel request) async {
    final uri = Uri.parse('${AppConstants.claudeBaseUrl}/messages');
    final response = await _client.post(
      uri,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode(<String, dynamic>{
        'model': model,
        'max_tokens': request.maxTokens,
        'temperature': request.temperature,
        if (request.systemPrompt != null && request.systemPrompt!.isNotEmpty)
          'system': request.systemPrompt,
        'messages': <Map<String, String>>[
          <String, String>{
            'role': 'user',
            'content': request.prompt,
          },
        ],
      }),
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final content = json['content'] as List<dynamic>? ?? const <dynamic>[];
      final text = content
          .whereType<Map<String, dynamic>>()
          .where((entry) => entry['type'] == 'text')
          .map((entry) => entry['text'] as String? ?? '')
          .join('\n')
          .trim();
      final usage = json['usage'] as Map<String, dynamic>? ?? const <String, dynamic>{};
      final inputTokens = usage['input_tokens'] as int? ?? 0;
      final outputTokens = usage['output_tokens'] as int? ?? 0;
      return AiResponseModel(
        text: text,
        model: json['model'] as String? ?? model,
        tokensUsed: inputTokens + outputTokens,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
    }
    throw ServerException(
      'Claude API error ${response.statusCode}: ${response.body}',
    );
  }
}
