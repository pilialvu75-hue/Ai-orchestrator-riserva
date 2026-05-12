import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_response_model.dart';

/// Remote data source that calls the **Google Gemini** generative language API.
///
/// Pass your API key via the [apiKey] constructor parameter (never hard-code
/// secrets — read them from a secure store or environment variables).
class GeminiDataSource {
  GeminiDataSource({
    required this.apiKey,
    http.Client? httpClient,
    this.model = 'gemini-1.5-flash',
  }) : _client = httpClient ?? http.Client();

  final String apiKey;
  final String model;
  final http.Client _client;
  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<AiResponseModel> complete(AiRequestModel request) async {
    final uri = Uri.parse(
      '${AppConstants.geminiBaseUrl}/models/$model:generateContent?key=$apiKey',
    );
    final body = jsonEncode(request.toGeminiJson());

    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return AiResponseModel.fromGeminiJson(json);
    } else {
      throw ServerException(
          'Gemini API error ${response.statusCode}: ${response.body}');
    }
  }
}
