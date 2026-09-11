import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_completion.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/claude_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/gemini_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/openai_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_response_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/repositories/ai_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('Cloud Point 1 completion semantics', () {
    test('OpenAI-compatible length finish is incomplete', () {
      final response = AiResponseModel.fromOpenAiJson(<String, dynamic>{
        'model': 'test-model',
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{'content': 'partial answer'},
            'finish_reason': 'length',
          },
        ],
        'usage': <String, dynamic>{
          'prompt_tokens': 12,
          'completion_tokens': 512,
          'total_tokens': 524,
        },
      });

      expect(response.completionStatus, CloudCompletionStatus.incomplete);
      expect(response.providerFinishReason, 'length');
      expect(response.inputTokens, 12);
      expect(response.outputTokens, 512);
    });

    test('Gemini MAX_TOKENS finish is incomplete and keeps reasoning usage', () {
      final response = AiResponseModel.fromGeminiJson(<String, dynamic>{
        'modelVersion': 'gemini-3.8-flash',
        'candidates': <Map<String, dynamic>>[
          <String, dynamic>{
            'finishReason': 'MAX_TOKENS',
            'content': <String, dynamic>{
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{'text': 'partial answer'},
              ],
            },
          },
        ],
        'usageMetadata': <String, dynamic>{
          'promptTokenCount': 20,
          'candidatesTokenCount': 100,
          'thoughtsTokenCount': 400,
          'totalTokenCount': 520,
        },
      });

      expect(response.completionStatus, CloudCompletionStatus.incomplete);
      expect(response.providerFinishReason, 'MAX_TOKENS');
      expect(response.reasoningTokens, 400);
    });

    test('Cloud adapter lifts legacy 512 budget without changing request core', () {
      const request = AiRequest(prompt: 'Explain this', maxTokens: 512);
      final model = AiRequestModel.fromEntity(request);
      final gemini = model.toGeminiJson(model: 'gemini-3.8-flash');
      final config = gemini['generationConfig'] as Map<String, dynamic>;

      expect(request.maxTokens, 512);
      expect(model.maxTokens, 2048);
      expect(config['maxOutputTokens'], 2048);
      expect(
        config['thinkingConfig'],
        <String, dynamic>{'thinkingLevel': 'LOW'},
      );
    });

    test('repository rejects HTTP-success Gemini incomplete output', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'modelVersion': 'gemini-3.8-flash',
            'candidates': <Map<String, dynamic>>[
              <String, dynamic>{
                'finishReason': 'MAX_TOKENS',
                'content': <String, dynamic>{
                  'parts': <Map<String, dynamic>>[
                    <String, dynamic>{'text': 'cut off'},
                  ],
                },
              },
            ],
            'usageMetadata': <String, dynamic>{'totalTokenCount': 2048},
          }),
          200,
        );
      });
      final repository = AiRepositoryImpl(
        openAiDataSource: OpenAiDataSource(apiKey: 'unused'),
        geminiDataSource: GeminiDataSource(apiKey: 'test', httpClient: client),
        claudeDataSource: ClaudeDataSource(apiKey: 'unused'),
      );

      final result = await repository.sendQueryWithProvider(
        'gemini',
        const AiRequest(prompt: 'test'),
      );

      result.fold(
        (failure) {
          expect(failure, isA<CloudFailure>());
          expect(
            (failure as CloudFailure).kind,
            CloudFailureKind.incompleteOutput,
          );
          expect(failure.retryable, isTrue);
        },
        (_) => fail('Incomplete response must not be reported as success.'),
      );
    });

    test('Gemini 503 is provider unavailable, never network unavailable', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode(<String, dynamic>{
              'error': <String, dynamic>{
                'code': 503,
                'message': 'This model is currently experiencing high demand.',
                'status': 'UNAVAILABLE',
              },
            }),
            503,
          ));
      final repository = AiRepositoryImpl(
        openAiDataSource: OpenAiDataSource(apiKey: 'unused'),
        geminiDataSource: GeminiDataSource(apiKey: 'test', httpClient: client),
        claudeDataSource: ClaudeDataSource(apiKey: 'unused'),
      );

      final result = await repository.sendQueryWithProvider(
        'gemini',
        const AiRequest(prompt: 'test'),
      );

      result.fold(
        (failure) {
          expect(failure, isA<CloudFailure>());
          final cloud = failure as CloudFailure;
          expect(cloud.kind, CloudFailureKind.providerUnavailable);
          expect(cloud.statusCode, 503);
          expect(cloud.retryable, isTrue);
          expect(cloud.message.toLowerCase(), contains('overloaded'));
          expect(cloud.message.toLowerCase(), isNot(contains('network')));
        },
        (_) => fail('HTTP 503 must not be reported as success.'),
      );
    });

    test('empty HTTP-success response is rejected', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode(<String, dynamic>{
              'modelVersion': 'gemini-3.8-flash',
              'candidates': <Map<String, dynamic>>[
                <String, dynamic>{
                  'finishReason': 'STOP',
                  'content': <String, dynamic>{'parts': <dynamic>[]},
                },
              ],
              'usageMetadata': <String, dynamic>{'totalTokenCount': 10},
            }),
            200,
          ));
      final repository = AiRepositoryImpl(
        openAiDataSource: OpenAiDataSource(apiKey: 'unused'),
        geminiDataSource: GeminiDataSource(apiKey: 'test', httpClient: client),
        claudeDataSource: ClaudeDataSource(apiKey: 'unused'),
      );

      final result = await repository.sendQueryWithProvider(
        'gemini',
        const AiRequest(prompt: 'test'),
      );

      result.fold(
        (failure) {
          expect(failure, isA<CloudFailure>());
          expect((failure as CloudFailure).kind, CloudFailureKind.emptyOutput);
        },
        (_) => fail('Empty response must not be reported as success.'),
      );
    });
  });
}
