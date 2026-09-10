import 'dart:convert';

import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/runtime/inference/custom_cloud_provider_store.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/custom_cloud_provider_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CustomCloudProviderProfile> createProfile({
    required String name,
    required String endpoint,
    required String model,
    required CustomCloudProviderProtocol protocol,
  }) {
    return CustomCloudProviderStore.instance.create(
      displayName: name,
      endpoint: endpoint,
      defaultModel: model,
      protocol: protocol,
      billing: CustomCloudProviderBilling.free,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    await CustomCloudProviderStore.instance.initialize(preferences: preferences);
  });

  test('executes an OpenAI-compatible custom provider', () async {
    final profile = await createProfile(
      name: 'Future OpenAI API',
      endpoint: 'https://future.example.test/v1/chat/completions',
      model: 'future-code-1',
      protocol: CustomCloudProviderProtocol.openAiCompatible,
    );

    Uri? uri;
    Map<String, String>? headers;
    Map<String, dynamic>? payload;
    final client = MockClient((request) async {
      uri = request.url;
      headers = request.headers;
      payload = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode(<String, dynamic>{
          'model': 'future-code-1',
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{'content': 'custom works'},
            },
          ],
          'usage': <String, dynamic>{'total_tokens': 7},
        }),
        200,
      );
    });

    final dataSource = CustomCloudProviderDataSource(
      httpClient: client,
      apiKeyProvider: (providerId) =>
          providerId == profile.id ? 'custom-key' : null,
    );
    final result = await dataSource.complete(
      profile.id,
      const AiRequestModel(prompt: 'build it', maxTokens: 128),
    );

    expect(uri, Uri.parse(profile.endpoint));
    expect(headers?['authorization'], 'Bearer custom-key');
    expect(payload?['model'], 'future-code-1');
    expect(result.text, 'custom works');
    expect(result.tokensUsed, 7);
  });

  test('executes an Anthropic-compatible custom provider', () async {
    final profile = await createProfile(
      name: 'Future Anthropic API',
      endpoint: 'https://future.example.test/v1/messages',
      model: 'future-sonnet',
      protocol: CustomCloudProviderProtocol.anthropicCompatible,
    );

    Map<String, String>? headers;
    Map<String, dynamic>? payload;
    final client = MockClient((request) async {
      headers = request.headers;
      payload = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode(<String, dynamic>{
          'model': 'future-sonnet',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'anthropic works'},
          ],
          'usage': <String, dynamic>{
            'input_tokens': 4,
            'output_tokens': 6,
          },
        }),
        200,
      );
    });

    final dataSource = CustomCloudProviderDataSource(
      httpClient: client,
      apiKeyProvider: (_) => 'anthropic-key',
    );
    final result = await dataSource.complete(
      profile.id,
      const AiRequestModel(
        prompt: 'review',
        systemPrompt: 'Be precise.',
        maxTokens: 128,
      ),
    );

    expect(headers?['x-api-key'], 'anthropic-key');
    expect(headers?['anthropic-version'], '2023-06-01');
    expect(payload?['model'], 'future-sonnet');
    expect(payload?['system'], 'Be precise.');
    expect(result.text, 'anthropic works');
    expect(result.tokensUsed, 10);
  });

  test('executes a Gemini-compatible custom provider with model placeholder',
      () async {
    final profile = await createProfile(
      name: 'Future Gemini API',
      endpoint:
          'https://future.example.test/v1/models/{model}:generateContent',
      model: 'future-flash',
      protocol: CustomCloudProviderProtocol.geminiCompatible,
    );

    Uri? uri;
    Map<String, String>? headers;
    final client = MockClient((request) async {
      uri = request.url;
      headers = request.headers;
      return http.Response(
        jsonEncode(<String, dynamic>{
          'modelVersion': 'future-flash',
          'candidates': <Map<String, dynamic>>[
            <String, dynamic>{
              'content': <String, dynamic>{
                'parts': <Map<String, String>>[
                  <String, String>{'text': 'gemini works'},
                ],
              },
            },
          ],
          'usageMetadata': <String, dynamic>{'totalTokenCount': 8},
        }),
        200,
      );
    });

    final dataSource = CustomCloudProviderDataSource(
      httpClient: client,
      apiKeyProvider: (_) => 'gemini-key',
    );
    final result = await dataSource.complete(
      profile.id,
      const AiRequestModel(prompt: 'plan', maxTokens: 128),
    );

    expect(
      uri,
      Uri.parse(
        'https://future.example.test/v1/models/future-flash:generateContent',
      ),
    );
    expect(headers?['x-goog-api-key'], 'gemini-key');
    expect(result.text, 'gemini works');
    expect(result.tokensUsed, 8);
  });

  test('missing custom credential fails before network', () async {
    final profile = await createProfile(
      name: 'No Key API',
      endpoint: 'https://future.example.test/v1/chat/completions',
      model: 'future-1',
      protocol: CustomCloudProviderProtocol.openAiCompatible,
    );
    var called = false;
    final client = MockClient((request) async {
      called = true;
      return http.Response('{}', 200);
    });

    final dataSource = CustomCloudProviderDataSource(
      httpClient: client,
      apiKeyProvider: (_) => null,
    );

    await expectLater(
      dataSource.complete(profile.id, const AiRequestModel(prompt: 'hello')),
      throwsA(isA<ServerException>()),
    );
    expect(called, isFalse);
  });
}
