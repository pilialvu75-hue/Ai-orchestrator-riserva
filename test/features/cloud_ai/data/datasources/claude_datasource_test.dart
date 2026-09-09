import 'dart:convert';

import 'package:ai_orchestrator/features/cloud_ai/data/datasources/claude_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('ClaudeDataSource', () {
    test('omits temperature for Claude Sonnet 5', () async {
      Map<String, dynamic>? payload;
      final client = MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'model': 'claude-sonnet-5',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'ok'},
            ],
            'usage': <String, dynamic>{
              'input_tokens': 1,
              'output_tokens': 1,
            },
          }),
          200,
        );
      });

      final dataSource = ClaudeDataSource(
        apiKey: 'test-key',
        model: 'claude-sonnet-5',
        httpClient: client,
      );

      await dataSource.complete(
        const AiRequestModel(
          prompt: 'hello',
          temperature: 0.45,
          maxTokens: 128,
        ),
      );

      expect(payload, isNotNull);
      expect(payload!['model'], 'claude-sonnet-5');
      expect(payload!.containsKey('temperature'), isFalse);
    });

    test('keeps temperature for Claude models that support it', () async {
      Map<String, dynamic>? payload;
      final client = MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'model': 'claude-haiku-4-5-20251001',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'ok'},
            ],
            'usage': <String, dynamic>{
              'input_tokens': 1,
              'output_tokens': 1,
            },
          }),
          200,
        );
      });

      final dataSource = ClaudeDataSource(
        apiKey: 'test-key',
        model: 'claude-haiku-4-5-20251001',
        httpClient: client,
      );

      await dataSource.complete(
        const AiRequestModel(
          prompt: 'hello',
          temperature: 0.45,
          maxTokens: 128,
        ),
      );

      expect(payload, isNotNull);
      expect(payload!['model'], 'claude-haiku-4-5-20251001');
      expect(payload!['temperature'], 0.45);
    });
  });
}
