import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_response_model.dart';

/// Remote data source that calls the **OpenAI Chat Completions** API.
///
/// Pass your API key via the [apiKey] constructor parameter (never hard-code
/// secrets — read them from a secure store or environment variables).
class OpenAiDataSource {
  OpenAiDataSource({
    required this.apiKey,
    http.Client? httpClient,
    this.model = 'gpt-4o',
  }) : _client = httpClient ?? http.Client();

  final String apiKey;
  final String model;
  final http.Client _client;
  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<AiResponseModel> complete(AiRequestModel request) async {
    final uri = Uri.parse('${AppConstants.openAiBaseUrl}/chat/completions');
    final body = jsonEncode(request.toOpenAiJson(model: model));

    final response = await _client.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: body,
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return AiResponseModel.fromOpenAiJson(json);
    } else {
      throw ServerException(
          'OpenAI API error ${response.statusCode}: ${response.body}');
    }
  }
}
