import 'dart:convert';

import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/custom_cloud_provider_store.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_response_model.dart';
import 'package:http/http.dart' as http;

/// Executes user-defined provider profiles that follow one of the supported
/// compatibility contracts. The endpoint stored in the profile is always the
/// exact request URL; Gemini-compatible URLs may use a `{model}` placeholder.
class CustomCloudProviderDataSource {
  CustomCloudProviderDataSource({
    http.Client? httpClient,
    CustomCloudProviderStore? store,
    String? Function(String providerId)? apiKeyProvider,
  })  : _client = httpClient ?? http.Client(),
        _store = store ?? CustomCloudProviderStore.instance,
        _apiKeyProvider = apiKeyProvider ?? CloudCredentialStore.instance.secretFor;

  final http.Client _client;
  final CustomCloudProviderStore _store;
  final String? Function(String providerId) _apiKeyProvider;

  bool isConfigured(String providerId) =>
      _store.contains(providerId) &&
      (_apiKeyProvider(providerId)?.trim().isNotEmpty ?? false);

  Future<AiResponseModel> complete(
    String providerId,
    AiRequestModel request,
  ) async {
    final profile = _store.profileFor(providerId);
    if (profile == null) {
      throw ServerException('Custom Cloud provider "$providerId" is not configured');
    }

    final credential = _apiKeyProvider(providerId)?.trim() ?? '';
    if (credential.isEmpty) {
      throw ServerException('${profile.displayName} API key not configured');
    }

    final model = _modelFor(profile, request);
    switch (profile.protocol) {
      case CustomCloudProviderProtocol.openAiCompatible:
        return _completeOpenAi(profile, credential, model, request);
      case CustomCloudProviderProtocol.anthropicCompatible:
        return _completeAnthropic(profile, credential, model, request);
      case CustomCloudProviderProtocol.geminiCompatible:
        return _completeGemini(profile, credential, model, request);
    }
  }

  Future<AiResponseModel> _completeOpenAi(
    CustomCloudProviderProfile profile,
    String credential,
    String model,
    AiRequestModel request,
  ) async {
    final response = await _client.post(
      Uri.parse(profile.endpoint),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $credential',
      },
      body: jsonEncode(request.toOpenAiJson(model: model)),
    );

    if (_isSuccess(response.statusCode)) {
      return AiResponseModel.fromOpenAiJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    throw _providerError(profile, response);
  }

  Future<AiResponseModel> _completeAnthropic(
    CustomCloudProviderProfile profile,
    String credential,
    String model,
    AiRequestModel request,
  ) async {
    final response = await _client.post(
      Uri.parse(profile.endpoint),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'x-api-key': credential,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode(<String, dynamic>{
        'model': model,
        'max_tokens': request.maxTokens,
        if (request.combinedSystemPrompt case final system?) 'system': system,
        'messages': request.toClaudeMessages(),
      }),
    );

    if (!_isSuccess(response.statusCode)) {
      throw _providerError(profile, response);
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final content = json['content'] as List<dynamic>? ?? const <dynamic>[];
    final text = content
        .whereType<Map<String, dynamic>>()
        .where((entry) => entry['type'] == 'text')
        .map((entry) => entry['text'] as String? ?? '')
        .where((value) => value.isNotEmpty)
        .join('\n')
        .trim();
    final usage = json['usage'] is Map
        ? Map<String, dynamic>.from(json['usage'] as Map)
        : const <String, dynamic>{};
    final input = _readInt(usage['input_tokens']);
    final output = _readInt(usage['output_tokens']);

    return AiResponseModel(
      text: text,
      model: json['model'] as String? ?? model,
      tokensUsed: input + output,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<AiResponseModel> _completeGemini(
    CustomCloudProviderProfile profile,
    String credential,
    String model,
    AiRequestModel request,
  ) async {
    final endpoint = profile.endpoint.replaceAll('{model}', model);
    final response = await _client.post(
      Uri.parse(endpoint),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'x-goog-api-key': credential,
      },
      body: jsonEncode(request.toGeminiJson(model: model)),
    );

    if (_isSuccess(response.statusCode)) {
      return AiResponseModel.fromGeminiJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    throw _providerError(profile, response);
  }

  String _modelFor(
    CustomCloudProviderProfile profile,
    AiRequestModel request,
  ) {
    final requested = request.modelId?.trim();
    return requested != null && requested.isNotEmpty
        ? requested
        : profile.defaultModel;
  }

  bool _isSuccess(int statusCode) => statusCode >= 200 && statusCode < 300;

  ServerException _providerError(
    CustomCloudProviderProfile profile,
    http.Response response,
  ) {
    return ServerException(
      '${profile.displayName} API error ${response.statusCode}: ${response.body}',
    );
  }

  int _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }
}
