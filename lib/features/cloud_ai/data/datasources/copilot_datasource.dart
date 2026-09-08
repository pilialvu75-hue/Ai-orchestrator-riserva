import 'dart:convert';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_response_model.dart';
import 'package:http/http.dart' as http;

class CopilotDataSource {
  CopilotDataSource({
    String apiKey = '',
    String Function()? apiKeyProvider,
    http.Client? httpClient,
    this.model = 'gpt-5.6-terra',
  })  : _apiKeyProvider = apiKeyProvider ??
            (() => CloudCredentialStore.instance.secretFor('copilot') ?? apiKey),
        _client = httpClient ?? http.Client();

  final String Function() _apiKeyProvider;
  final String model;
  final http.Client _client;

  String get apiKey => _apiKeyProvider().trim();
  bool get isConfigured => apiKey.isNotEmpty;

  Future<AiResponseModel> complete(AiRequestModel request) async {
    final credential = apiKey;
    if (credential.isEmpty) {
      throw const ServerException('Copilot credential not configured');
    }

    final resolvedModel = _modelFor(request);
    final uri = Uri.parse(AppConstants.copilotChatUrl);
    final body = jsonEncode(
      request.toOpenAiJson(model: resolvedModel),
    );

    final response = await _client.post(
      uri,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $credential',
      },
      body: body,
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return AiResponseModel.fromOpenAiJson(json);
    }

    throw ServerException(
      'Copilot API error ${response.statusCode}: ${response.body}',
    );
  }

  String _modelFor(AiRequestModel request) {
    final requested = request.modelId?.trim();
    return requested != null && requested.isNotEmpty ? requested : model;
  }
}
