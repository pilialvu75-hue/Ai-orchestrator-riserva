import 'dart:convert';

import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_response_model.dart';
import 'package:http/http.dart' as http;

/// Remote data source for NVIDIA-hosted NIM LLM endpoints.
///
/// NVIDIA NIM exposes an OpenAI-compatible Chat Completions surface. This
/// adapter deliberately contains no routing or spending assumptions: NVIDIA's
/// hosted "Free Endpoint" is suitable for development/prototyping, but its
/// entitlement must be classified separately from a recurring production free
/// tier by the Cloud policy layer.
class NvidiaNimDataSource {
  NvidiaNimDataSource({
    String apiKey = '',
    String Function()? apiKeyProvider,
    http.Client? httpClient,
    this.model = 'nvidia/nemotron-3-ultra-550b-a55b',
  })  : _apiKeyProvider = apiKeyProvider ??
            (() => CloudCredentialStore.instance.secretFor('nvidia') ?? apiKey),
        _client = httpClient ?? http.Client();

  static const String _chatCompletionsUrl =
      'https://integrate.api.nvidia.com/v1/chat/completions';

  final String Function() _apiKeyProvider;
  final String model;
  final http.Client _client;

  String get apiKey => _apiKeyProvider().trim();
  bool get isConfigured => apiKey.isNotEmpty;

  Future<AiResponseModel> complete(AiRequestModel request) async {
    final credential = apiKey;
    if (credential.isEmpty) {
      throw const ServerException('NVIDIA NIM API key not configured');
    }

    final resolvedModel = _modelFor(request);
    final response = await _client.post(
      Uri.parse(_chatCompletionsUrl),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $credential',
      },
      body: jsonEncode(request.toOpenAiJson(model: resolvedModel)),
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return AiResponseModel.fromOpenAiJson(json);
    }

    throw ServerException(
      'NVIDIA NIM API error ${response.statusCode}: ${response.body}',
    );
  }

  String _modelFor(AiRequestModel request) {
    final requested = request.modelId?.trim();
    return requested != null && requested.isNotEmpty ? requested : model;
  }
}
