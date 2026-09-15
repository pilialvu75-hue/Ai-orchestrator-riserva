import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:ai_orchestrator/core/runtime/inference/assistant_web_continuation_local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';

class _MockLocalRuntimeProvider extends Mock implements LocalRuntimeProvider {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const InferenceRequest(
        sessionId: 'fallback',
        prompt: 'fallback',
      ),
    );
    registerFallbackValue(CancellationToken());
  });

  late _MockLocalRuntimeProvider delegate;
  late AssistantWebContinuationLocalRuntimeProvider provider;

  setUp(() {
    delegate = _MockLocalRuntimeProvider();
    provider = AssistantWebContinuationLocalRuntimeProvider(delegate: delegate);
    when(
      () => delegate.streamInference(
        request: any(named: 'request'),
        cancellationToken: any(named: 'cancellationToken'),
      ),
    ).thenAnswer(
      (_) => Stream<InferenceResponse>.value(
        InferenceResponse.finalChunk(
          text: 'ok',
          tokensGenerated: 1,
          model: 'test',
        ),
      ),
    );
  });

  test('rewrites successful post-search continuation before Local prompt build',
      () async {
    final token = CancellationToken();
    final request = const InferenceRequest(
      sessionId: 'assistant::search',
      prompt: 'Che meteo fa oggi a Parigi?\n\n'
          '[INTERNET SEARCH RESULTS]\n'
          '1. Paris weather\nURL: https://example.test/weather\n\n'
          "Use the information above to accurately complete the user's original request.",
      systemPrompt: 'Base prompt.',
      modelId: 'phi3_5_mini',
      modelPath: '/models/phi.gguf',
    );

    final chunks = await provider
        .streamInference(request: request, cancellationToken: token)
        .toList();

    expect(chunks.single.text, 'ok');
    final captured = verify(
      () => delegate.streamInference(
        request: captureAny(named: 'request'),
        cancellationToken: token,
      ),
    ).captured.single as InferenceRequest;

    expect(captured.prompt, isNot(contains('meteo')));
    expect(captured.prompt, isNot(contains('[INTERNET SEARCH RESULTS]')));
    expect(captured.systemPrompt, contains('Original user request:'));
    expect(captured.systemPrompt, contains('Che meteo fa oggi a Parigi?'));
    expect(captured.systemPrompt, contains('[WEB SEARCH RESULTS]'));
    expect(captured.systemPrompt, contains('https://example.test/weather'));
    expect(captured.systemPrompt, contains('Do not request another lookup.'));
    expect(captured.modelId, 'phi3_5_mini');
    expect(captured.modelPath, '/models/phi.gguf');
  });

  test('empty search evidence becomes an offline-safe continuation', () async {
    final token = CancellationToken();
    final request = const InferenceRequest(
      sessionId: 'assistant::search',
      prompt: 'Ultime notizie?\n\n'
          '[INTERNET SEARCH RESULTS]\n\n'
          "Use the information above to accurately complete the user's original request.",
      systemPrompt: 'Base prompt.',
    );

    await provider
        .streamInference(request: request, cancellationToken: token)
        .drain<void>();

    final captured = verify(
      () => delegate.streamInference(
        request: captureAny(named: 'request'),
        cancellationToken: token,
      ),
    ).captured.single as InferenceRequest;

    expect(captured.systemPrompt, contains('[WEB SEARCH UNAVAILABLE]'));
    expect(captured.systemPrompt, contains('Continue from local knowledge'));
    expect(captured.prompt, isNot(contains('Ultime notizie')));
  });

  test('ordinary Local inference passes through unchanged', () async {
    final token = CancellationToken();
    final request = const InferenceRequest(
      sessionId: 'assistant',
      prompt: 'Spiegami la fotosintesi.',
      systemPrompt: 'Base prompt.',
    );

    await provider
        .streamInference(request: request, cancellationToken: token)
        .drain<void>();

    final captured = verify(
      () => delegate.streamInference(
        request: captureAny(named: 'request'),
        cancellationToken: token,
      ),
    ).captured.single as InferenceRequest;

    expect(captured.sessionId, request.sessionId);
    expect(captured.prompt, request.prompt);
    expect(captured.systemPrompt, request.systemPrompt);
  });
}
