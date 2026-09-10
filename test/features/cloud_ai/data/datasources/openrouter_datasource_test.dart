import 'dart:convert';

import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/openrouter_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('OpenRouterDataSource', () {
    test('uses free router and preserves the concrete routed model identity',
        () async {
      Uri? uri;
      Map<String, String>? headers;
      Map<String, dynamic>? payload;

      final client = MockClient((request) async {
        uri = request.url;
        headers = request.headers;
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'model': 'nvidia/nemotron-3-ultra-550b-a55b:free',
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': 'second opinion'},
              },
            ],
            'usage': <String, dynamic>{'total_tokens': 18},
          }),
          200,
        );
      });

      final dataSource = OpenRouterDataSource(
        apiKey: 'openrouter-test-key',
        httpClient: client,
      );

      final result = await dataSource.complete(
        const AiRequestModel(prompt: 'review', maxTokens: 256),
      );

      expect(
        uri,
        Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
      );
      expect(headers?['authorization'], 'Bearer openrouter-test-key');
      expect(headers?['x-title'], 'AI-Orchestrator');
      expect(payload?['model'], 'openrouter/free');
      expect(result.text, 'second opinion');
      expect(result.model, 'nvidia/nemotron-3-ultra-550b-a55b:free');
      expect(result.tokensUsed, 18);
    });

    test('honors an explicit free-model override', () async {
      Map<String, dynamic>? payload;
      final client = MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'model': 'openai/gpt-oss-120b:free',
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': 'ok'},
              },
            ],
            'usage': <String, dynamic>{'total_tokens': 2},
          }),
          200,
        );
      });

      final dataSource = OpenRouterDataSource(
        apiKey: 'openrouter-test-key',
        httpClient: client,
      );

      await dataSource.complete(
        const AiRequestModel(
          prompt: 'reason',
          modelId: 'openai/gpt-oss-120b:free',
        ),
      );

      expect(payload?['model'], 'openai/gpt-oss-120b:free');
    });

    test('fails before network when no credential is configured', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      });
      final dataSource = OpenRouterDataSource(httpClient: client);

      expect(
        () => dataSource.complete(const AiRequestModel(prompt: 'hello')),
        throwsA(isA<ServerException>()),
      );
      expect(called, isFalse);
    });

    test('surfaces non-success OpenRouter responses as ServerException',
        () async {
      final client = MockClient(
        (request) async => http.Response('{"error":"rate limited"}', 429),
      );
      final dataSource = OpenRouterDataSource(
        apiKey: 'openrouter-test-key',
        httpClient: client,
      );

      expect(
        () => dataSource.complete(const AiRequestModel(prompt: 'hello')),
        throwsA(
          isA<ServerException>().having(
            (error) => error.message,
            'message',
            contains('OpenRouter API error 429'),
          ),
        ),
      );
    });
  });
}
