import 'dart:convert';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_response_model.dart';
import 'package:http/http.dart' as http;

/// Remote data source for the Google Gemini generateContent API.
class GeminiDataSource {
  GeminiDataSource({
    required this.apiKey,
    http.Client? httpClient,
    this.model = 'gemini-3.8-flash',
  }) : _client = httpClient ?? http.Client();

  final String apiKey;
  final String model;
  final http.Client _client;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<AiResponseModel> complete(AiRequestModel request) async {
    final resolvedModel = _modelFor(request);
    final uri = Uri.parse(
      '${AppConstants.geminiBaseUrl}/models/$resolvedModel:generateContent',
    );
    final body = jsonEncode(
      request.toGeminiJson(model: resolvedModel),
    );

    final response = await _client.post(
      uri,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      },
      body: body,
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return AiResponseModel.fromGeminiJson(json);
    }

    throw ServerException(
      'Gemini API error ${response.statusCode}: ${response.body}',
    );
  }

  String _modelFor(AiRequestModel request) {
    final requested = request.modelId?.trim();
    return requested != null && requested.isNotEmpty ? requested : model;
  }
}
