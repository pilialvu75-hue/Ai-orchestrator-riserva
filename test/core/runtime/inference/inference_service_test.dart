import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';

void main() {
  const validModel = AiModel(
    id: 'gemma_2b',
    displayName: 'Gemma 2B',
    fileName: 'gemma.gguf',
    downloadUrl: 'https://example.com/model.gguf',
    version: '1.0.0',
    sizeBytes: 123,
    description: 'Test model',
    isDownloaded: true,
    localPath: '/tmp/gemma.gguf',
    validationStatus: ModelValidationStatus.validatedOk,
  );

  InferenceService buildService({
    required AiRuntimeMode mode,
    AiModel? selectedModel,
    required FakeLocalRuntimeProvider localRuntimeProvider,
    required CloudRuntimeProvider cloudRuntimeProvider,
    Tool? webSearchTool,
  }) {
    return InferenceService(
      loadSelectedModel: () async => selectedModel,
      loadRuntimeMode: () async => mode,
      runtimeProvider: localRuntimeProvider,
      cloudRuntimeProvider: cloudRuntimeProvider,
      sessionManager: RuntimeSessionManager(),
      webSearchTool: webSearchTool,
    );
  }

  /// Builds a [CloudRuntimeProvider] suitable for testing.
  ///
  /// [configured] controls whether the provider reports itself as available.
  /// When [false] the cloud provider appears unconfigured and
  /// [InferenceService] falls back to local mode or reports an error.
  CloudRuntimeProvider buildCloudProvider({
    bool configured = true,
    Future<AiResponse> Function(String provider, AiRequest request)? sendQuery,
  }) {
    return CloudRuntimeProvider(
      sendQuery: sendQuery ??
          (_, __) async => AiResponse(
                text: 'Cloud response',
                model: 'gpt-4o',
                tokensUsed: 8,
                timestamp: DateTime.now().millisecondsSinceEpoch,
              ),
      supportedProviders: () => <String>['openAi'],
      isProviderAvailable: (_) => configured,
      providerDisplayName: ([providerName]) => 'OpenAI',
    );
  }

  group('InferenceService routing', () {
    test('local mode returns streamed final response', () async {
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          responses: <InferenceResponse>[
            InferenceResponse.token(text: 'Hello ', model: 'gemma_2b'),
            InferenceResponse.token(text: 'world', model: 'gemma_2b'),
            InferenceResponse.finalChunk(
              text: 'Hello world',
              tokensGenerated: 2,
              model: 'gemma_2b',
            ),
          ],
        ),
        cloudRuntimeProvider: buildCloudProvider(),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 'local-stream', prompt: 'hello'),
      );

      expect(response.isError, false);
      expect(response.text, 'Hello world');
      expect(response.model, 'gemma_2b');
      expect(response.tokensGenerated, 2);
    });

    test('cancel propagates to local runtime stream', () async {
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (_, cancellationToken) async* {
            yield InferenceResponse.token(text: 'partial', model: 'gemma_2b');
            while (!cancellationToken.isCancelled) {
              await Future<void>.delayed(const Duration(milliseconds: 2));
              yield InferenceResponse.token(text: '.', model: 'gemma_2b');
            }
            yield InferenceResponse.error('Inference cancelled.');
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(),
      );

      final streamFuture = service
          .stream(const InferenceRequest(sessionId: 'cancel-s1', prompt: 'hello'))
          .toList();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      service.cancel('cancel-s1');

      final chunks = await streamFuture;
      expect(chunks.any((chunk) => chunk.isError), true);
    });

    test('starting a new inference cancels the previous session', () async {
      final startedSessions = <String>[];
      final cancelledSessions = <String>[];
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (request, cancellationToken) async* {
            startedSessions.add(request.sessionId);
            cancellationToken.onCancel(() {
              cancelledSessions.add(request.sessionId);
            });
            yield InferenceResponse.token(
              text: request.sessionId,
              model: 'gemma_2b',
            );
            while (!cancellationToken.isCancelled) {
              await Future<void>.delayed(const Duration(milliseconds: 2));
            }
            yield InferenceResponse.error('Inference cancelled.');
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(),
      );

      final firstStream = service
          .stream(const InferenceRequest(sessionId: 'session-1', prompt: 'hello'))
          .toList();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final secondChunks = await service
          .stream(const InferenceRequest(sessionId: 'session-2', prompt: 'world'))
          .take(1)
          .toList();
      final firstChunks = await firstStream;

      expect(startedSessions, <String>['session-1', 'session-2']);
      expect(cancelledSessions, <String>['session-1']);
      expect(firstChunks.any((chunk) => chunk.isError), true);
      expect(secondChunks.single.text, 'session-2');
    });

    test('returns error when cloud mode has no API key and no local model',
        () async {
      final service = buildService(
        mode: AiRuntimeMode.cloud,
        selectedModel: null,
        localRuntimeProvider: FakeLocalRuntimeProvider(),
        cloudRuntimeProvider: buildCloudProvider(configured: false),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 's1', prompt: 'hello'),
      );

      expect(response.isError, true);
      // When no provider is available and no local model exists, the
      // CloudRuntimeProvider emits its "fully local" notice as an error and
      // InferenceService propagates it.
      expect(response.errorMessage, CloudRuntimeProvider.fullyLocalNotice);
    });

    test('fails explicitly when cloud mode is selected without API key',
        () async {
      var cloudCalls = 0;
      var localCalls = 0;
      final service = buildService(
        mode: AiRuntimeMode.cloud,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (_, __) async* {
            localCalls += 1;
            yield InferenceResponse.finalChunk(
              text: 'Local response',
              tokensGenerated: 4,
              model: 'gemma_2b',
            );
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(
          configured: false,
          sendQuery: (_, __) async {
            cloudCalls += 1;
            throw AssertionError('cloud should not be called');
          },
        ),
      );

      final chunks = await service
          .stream(const InferenceRequest(sessionId: 's2', prompt: 'hello'))
          .toList();
      final terminal = chunks.last;

      expect(terminal.isError, true);
      expect(
        terminal.terminalState,
        anyOf(
          InferenceTerminalState.modelUnavailable,
          InferenceTerminalState.failed,
        ),
      );
      expect(localCalls, 0);
      expect(cloudCalls, 0);
    });

    test('falls back to local when cloud authentication fails', () async {
      final service = buildService(
        mode: AiRuntimeMode.cloud,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          responses: <InferenceResponse>[
            InferenceResponse.finalChunk(
              text: 'Recovered locally',
              tokensGenerated: 6,
              model: 'gemma_2b',
            ),
          ],
        ),
        cloudRuntimeProvider: buildCloudProvider(
          sendQuery: (_, __) async => throw const ServerFailure(
            'OpenAI API error 401: invalid_api_key',
          ),
        ),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 's3', prompt: 'hello'),
      );

      expect(response.isError, false);
      expect(response.text, 'Recovered locally');
      expect(response.model, 'gemma_2b');
    });

    test('hybrid mode falls back to cloud when local startup fails', () async {
      final service = buildService(
        mode: AiRuntimeMode.hybrid,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          responses: <InferenceResponse>[
            InferenceResponse.error('Missing local model path.'),
          ],
        ),
        cloudRuntimeProvider: buildCloudProvider(),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 's4', prompt: 'hello'),
      );

      expect(response.isError, false);
      expect(response.text, 'Cloud response');
      expect(response.model, 'gpt-4o');
    });

    test('local search continuation uses a fresh cancellation token', () async {
      final searchTool = _FakeWebSearchTool(
        const ToolResult(
          toolId: 'web_search',
          output: '''
Query: weather in rome
Top results:
1. Rome forecast
   URL: https://example.com/rome
   Snippet: Sunny.
''',
          success: true,
        ),
      );
      var streamInvocations = 0;
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: const AiModel(
          id: 'phi3_5_mini',
          displayName: 'Phi-3.5 Mini Instruct',
          fileName: 'phi3.gguf',
          downloadUrl: 'https://example.com/model.gguf',
          version: '1.0.0',
          sizeBytes: 123,
          description: 'Test model',
          isDownloaded: true,
          localPath: '/tmp/phi3.gguf',
          validationStatus: ModelValidationStatus.validatedOk,
        ),
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (request, cancellationToken) async* {
            streamInvocations += 1;
            if (streamInvocations == 1) {
              expect(cancellationToken.isCancelled, isFalse);
              yield InferenceResponse.token(
                text: '<search>weather in rome</search>',
                model: 'phi3_5_mini',
              );
              return;
            }

            expect(cancellationToken.isCancelled, isFalse);
            expect(request.prompt, contains('[INTERNET SEARCH RESULTS]'));
            yield InferenceResponse.finalChunk(
              text: 'Rome weather is sunny.',
              tokensGenerated: 5,
              model: 'phi3_5_mini',
            );
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(),
        webSearchTool: searchTool,
      );

      final response = await service.infer(
        const InferenceRequest(
          sessionId: 'search-s1',
          prompt: 'What is the weather in Rome?',
        ),
      );

      expect(response.isError, false);
      expect(response.text, 'Rome weather is sunny.');
      expect(searchTool.calls, 1);
      expect(streamInvocations, 2);
    });
  });
}

class FakeLocalRuntimeProvider extends LocalRuntimeProvider {
  FakeLocalRuntimeProvider({
    this.responses = const <InferenceResponse>[],
    this.isSupported = true,
    this.streamBuilder,
  });

  final List<InferenceResponse> responses;
  final bool isSupported;
  final TokenStream Function(
    InferenceRequest request,
    CancellationToken cancellationToken,
  )? streamBuilder;

  @override
  bool supportsModel(AiModel model) => isSupported;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    if (streamBuilder != null) {
      yield* streamBuilder!(request, cancellationToken);
      return;
    }
    for (final response in responses) {
      yield response;
    }
  }
}

class _FakeWebSearchTool implements Tool {
  _FakeWebSearchTool(this._result);

  final ToolResult _result;
  var calls = 0;

  @override
  String get id => 'web_search';

  @override
  String get name => 'Web Search';

  @override
  String get description => 'Fake web search tool for tests.';

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    calls += 1;
    expect(params['query'], isNotEmpty);
    return _result;
  }
}
