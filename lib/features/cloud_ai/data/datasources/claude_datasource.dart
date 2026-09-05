import 'dart:convert';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_response_model.dart';
import 'package:http/http.dart' as http;

class ClaudeDataSource {
  ClaudeDataSource({
    String apiKey = '',
    String Function()? apiKeyProvider,
    http.Client? httpClient,
    this.model = 'claude-sonnet-5',
  })  : _apiKeyProvider = apiKeyProvider ?? (() => apiKey),
        _client = httpClient ?? http.Client();

  final String Function() _apiKeyProvider;
  final String model;
  final http.Client _client;

  String get apiKey => _apiKeyProvider().trim();
  bool get isConfigured => apiKey.isNotEmpty;

  Future<AiResponseModel> complete(AiRequestModel request) async {
    final credential = apiKey;
    if (credential.isEmpty) {
      throw const ServerException('Claude API key not configured');
    }

    final resolvedModel = _modelFor(request);
    final uri = Uri.parse('${AppConstants.claudeBaseUrl}/messages');
    final response = await _client.post(
      uri,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'x-api-key': credential,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode(<String, dynamic>{
        'model': resolvedModel,
        'max_tokens': request.maxTokens,
        'temperature': request.temperature,
        if (request.combinedSystemPrompt case final system?)
          'system': system,
        'messages': request.toClaudeMessages(),
      }),
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final content = json['content'] as List<dynamic>? ?? const <dynamic>[];
      final text = content
          .whereType<Map<String, dynamic>>()
          .where((entry) => entry['type'] == 'text')
          .map((entry) => entry['text'] as String? ?? '')
          .where((value) => value.isNotEmpty)
          .join('\n')
          .trim();
      final usage =
          json['usage'] as Map<String, dynamic>? ?? const <String, dynamic>{};
      final inputTokens = usage['input_tokens'] as int? ?? 0;
      final outputTokens = usage['output_tokens'] as int? ?? 0;
      return AiResponseModel(
        text: text,
        model: json['model'] as String? ?? resolvedModel,
        tokensUsed: inputTokens + outputTokens,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
    }

    throw ServerException(
      'Claude API error ${response.statusCode}: ${response.body}',
    );
  }

  String _modelFor(AiRequestModel request) {
    final requested = request.modelId?.trim();
    return requested != null && requested.isNotEmpty ? requested : model;
  }
}
