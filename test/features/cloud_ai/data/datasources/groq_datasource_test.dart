import 'dart:convert';

import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/groq_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('GroqDataSource', () {
    test('uses Groq endpoint, bearer auth, and coding default model', () async {
      Uri? uri;
      Map<String, String>? headers;
      Map<String, dynamic>? payload;

      final client = MockClient((request) async {
        uri = request.url;
        headers = request.headers;
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'model': 'qwen/qwen3.8-27b',
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': 'working'},
              },
            ],
            'usage': <String, dynamic>{'total_tokens': 12},
          }),
          200,
        );
      });

      final dataSource = GroqDataSource(
        apiKey: 'groq-test-key',
        httpClient: client,
      );

      final result = await dataSource.complete(
        const AiRequestModel(
          prompt: 'fix this code',
          temperature: 0.2,
          maxTokens: 256,
        ),
      );

      expect(
        uri,
        Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
      );
      expect(headers?['authorization'], 'Bearer groq-test-key');
      expect(payload?['model'], 'qwen/qwen3.8-27b');
      expect(result.text, 'working');
      expect(result.model, 'qwen/qwen3.8-27b');
      expect(result.tokensUsed, 12);
    });

    test('honors an explicit model override', () async {
      Map<String, dynamic>? payload;
      final client = MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'model': 'openai/gpt-oss-120b',
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

      final dataSource = GroqDataSource(
        apiKey: 'groq-test-key',
        httpClient: client,
      );

      await dataSource.complete(
        const AiRequestModel(
          prompt: 'reason',
          modelId: 'openai/gpt-oss-120b',
        ),
      );

      expect(payload?['model'], 'openai/gpt-oss-120b');
    });

    test('fails before network when no credential is configured', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      });

      final dataSource = GroqDataSource(httpClient: client);

      expect(
        () => dataSource.complete(const AiRequestModel(prompt: 'hello')),
        throwsA(isA<ServerException>()),
      );
      expect(called, isFalse);
    });

    test('surfaces non-success Groq responses as ServerException', () async {
      final client = MockClient(
        (request) async => http.Response('{"error":"rate limited"}', 429),
      );
      final dataSource = GroqDataSource(
        apiKey: 'groq-test-key',
        httpClient: client,
      );

      expect(
        () => dataSource.complete(const AiRequestModel(prompt: 'hello')),
        throwsA(
          isA<ServerException>().having(
            (error) => error.message,
            'message',
            contains('Groq API error 429'),
          ),
        ),
      );
    });
  });
}
