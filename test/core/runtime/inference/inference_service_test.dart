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
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

void main() {
  setUp(() {
    RuntimeEventLog.instance.resetForTest();
  });

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
  }) {
    return InferenceService(
      loadSelectedModel: () async => selectedModel,
      loadRuntimeMode: () async => mode,
      runtimeProvider: localRuntimeProvider,
      cloudRuntimeProvider: cloudRuntimeProvider,
      sessionManager: RuntimeSessionManager(),
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

    test('emits forensic inference and provider markers through runtime diagnostics',
        () async {
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          responses: <InferenceResponse>[
            InferenceResponse.finalChunk(
              text: 'Hello world',
              tokensGenerated: 2,
              model: 'gemma_2b',
            ),
          ],
        ),
        cloudRuntimeProvider: buildCloudProvider(),
      );

      await service
          .stream(const InferenceRequest(sessionId: 'forensic-s1', prompt: 'hello'))
          .toList();

      final messages = RuntimeEventLog.instance.entries
          .map((entry) => entry.message)
          .toList(growable: false);
      expect(
        messages,
        contains(
          '[FORENSIC_INFERENCE_SERVICE_ENTRY] session=forensic-s1 prompt_chars=5 context_lines=0 offline=false',
        ),
      );
      expect(
        messages,
        contains(
          '[FORENSIC_PROVIDER_ENTRY] session=forensic-s1 provider=FakeLocalRuntimeProvider mode=local',
        ),
      );
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
