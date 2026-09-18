import 'dart:convert';

import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/mistral_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('MistralDataSource', () {
    test('uses Mistral endpoint, bearer auth, and conservative free-mode default',
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
            'model': 'mistral-small-latest',
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': 'done'},
              },
            ],
            'usage': <String, dynamic>{'total_tokens': 15},
          }),
          200,
        );
      });

      final dataSource = MistralDataSource(
        apiKey: 'mistral-test-key',
        httpClient: client,
      );

      final result = await dataSource.complete(
        const AiRequestModel(
          prompt: 'review this function',
          temperature: 0.2,
          maxTokens: 256,
        ),
      );

      expect(uri, Uri.parse('https://api.mistral.ai/v1/chat/completions'));
      expect(headers?['authorization'], 'Bearer mistral-test-key');
      expect(payload?['model'], 'mistral-small-latest');
      expect(result.text, 'done');
      expect(result.tokensUsed, 15);
    });

    test('honors an explicit stronger-model override', () async {
      Map<String, dynamic>? payload;
      final client = MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'model': 'mistral-medium-3-5',
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

      final dataSource = MistralDataSource(
        apiKey: 'mistral-test-key',
        httpClient: client,
      );

      await dataSource.complete(
        const AiRequestModel(
          prompt: 'architect',
          modelId: 'mistral-medium-3-5',
        ),
      );

      expect(payload?['model'], 'mistral-medium-3-5');
    });

    test('fails before network when no credential is configured', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      });
      final dataSource = MistralDataSource(httpClient: client);

      expect(
        () => dataSource.complete(const AiRequestModel(prompt: 'hello')),
        throwsA(isA<ServerException>()),
      );
      expect(called, isFalse);
    });

    test('surfaces non-success Mistral responses as ServerException', () async {
      final client = MockClient(
        (request) async => http.Response('{"error":"rate limited"}', 429),
      );
      final dataSource = MistralDataSource(
        apiKey: 'mistral-test-key',
        httpClient: client,
      );

      expect(
        () => dataSource.complete(const AiRequestModel(prompt: 'hello')),
        throwsA(
          isA<ServerException>().having(
            (error) => error.message,
            'message',
            contains('Mistral API error 429'),
          ),
        ),
      );
    });
  });
}
