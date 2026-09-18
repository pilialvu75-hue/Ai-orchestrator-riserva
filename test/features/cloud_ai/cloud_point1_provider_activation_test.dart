import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/claude_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/gemini_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/groq_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/mistral_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/nvidia_nim_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/openai_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/openrouter_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/repositories/ai_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('Cloud Point 1.5 built-in provider activation', () {
    test('Groq, NVIDIA NIM, Mistral and OpenRouter execute through repository', () async {
      final requestedHosts = <String>[];
      final client = MockClient((request) async {
        requestedHosts.add(request.url.host);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'model': body['model'],
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': 'provider works'},
                'finish_reason': 'stop',
              },
            ],
            'usage': <String, dynamic>{'total_tokens': 7},
          }),
          200,
        );
      });

      final repository = AiRepositoryImpl(
        openAiDataSource: OpenAiDataSource(apiKey: 'unused'),
        geminiDataSource: GeminiDataSource(apiKey: 'unused'),
        claudeDataSource: ClaudeDataSource(apiKey: 'unused'),
        groqDataSource: GroqDataSource(apiKey: 'groq-test', httpClient: client),
        nvidiaNimDataSource:
            NvidiaNimDataSource(apiKey: 'nvidia-test', httpClient: client),
        mistralDataSource:
            MistralDataSource(apiKey: 'mistral-test', httpClient: client),
        openRouterDataSource:
            OpenRouterDataSource(apiKey: 'openrouter-test', httpClient: client),
      );

      for (final provider in <String>[
        'groq',
        'nvidiaNim',
        'mistral',
        'openRouter',
      ]) {
        expect(repository.supportedProviders, contains(provider));
        expect(repository.isProviderAvailable(provider), isTrue);
        final result = await repository.sendQueryWithProvider(
          provider,
          const AiRequest(prompt: 'test'),
        );
        result.fold(
          (failure) => fail('$provider failed: ${failure.message}'),
          (response) => expect(response.text, 'provider works'),
        );
      }

      expect(
        requestedHosts,
        <String>[
          'api.groq.com',
          'integrate.api.nvidia.com',
          'api.mistral.ai',
          'openrouter.ai',
        ],
      );
    });
  });
}
