import 'dart:convert';

import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/nvidia_nim_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('NvidiaNimDataSource', () {
    test('uses NVIDIA NIM endpoint, bearer auth, and Nemotron default', () async {
      Uri? uri;
      Map<String, String>? headers;
      Map<String, dynamic>? payload;

      final client = MockClient((request) async {
        uri = request.url;
        headers = request.headers;
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'model': 'nvidia/nemotron-3-ultra-550b-a55b',
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': 'review complete'},
              },
            ],
            'usage': <String, dynamic>{'total_tokens': 21},
          }),
          200,
        );
      });

      final dataSource = NvidiaNimDataSource(
        apiKey: 'nvidia-test-key',
        httpClient: client,
      );

      final result = await dataSource.complete(
        const AiRequestModel(
          prompt: 'review this architecture',
          temperature: 0.7,
          maxTokens: 512,
        ),
      );

      expect(
        uri,
        Uri.parse('https://integrate.api.nvidia.com/v1/chat/completions'),
      );
      expect(headers?['authorization'], 'Bearer nvidia-test-key');
      expect(payload?['model'], 'nvidia/nemotron-3-ultra-550b-a55b');
      expect(result.text, 'review complete');
      expect(result.tokensUsed, 21);
    });

    test('honors an explicit model override', () async {
      Map<String, dynamic>? payload;
      final client = MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'model': 'deepseek-ai/deepseek-v4-pro-0813',
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

      final dataSource = NvidiaNimDataSource(
        apiKey: 'nvidia-test-key',
        httpClient: client,
      );

      await dataSource.complete(
        const AiRequestModel(
          prompt: 'solve',
          modelId: 'deepseek-ai/deepseek-v4-pro-0813',
        ),
      );

      expect(payload?['model'], 'deepseek-ai/deepseek-v4-pro-0813');
    });

    test('fails before network when no credential is configured', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      });
      final dataSource = NvidiaNimDataSource(httpClient: client);

      expect(
        () => dataSource.complete(const AiRequestModel(prompt: 'hello')),
        throwsA(isA<ServerException>()),
      );
      expect(called, isFalse);
    });

    test('surfaces non-success NVIDIA responses as ServerException', () async {
      final client = MockClient(
        (request) async => http.Response('{"error":"quota"}', 429),
      );
      final dataSource = NvidiaNimDataSource(
        apiKey: 'nvidia-test-key',
        httpClient: client,
      );

      expect(
        () => dataSource.complete(const AiRequestModel(prompt: 'hello')),
        throwsA(
          isA<ServerException>().having(
            (error) => error.message,
            'message',
            contains('NVIDIA NIM API error 429'),
          ),
        ),
      );
    });
  });
}
