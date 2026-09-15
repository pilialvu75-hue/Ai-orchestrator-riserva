import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:ai_orchestrator/core/orchestrator/assistant_web_aware_orchestrator.dart';
import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';
import 'package:ai_orchestrator/core/orchestrator/intent_analyzer.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';
import 'package:ai_orchestrator/core/tools/web_search_tool.dart';

class _MockExecutionEngine extends Mock implements ExecutionEngine {}
class _MockInferenceService extends Mock implements InferenceService {}
class _MockWebSearchTool extends Mock implements WebSearchTool {}
class _MockRuntimeSettings extends Mock implements AiRuntimeSettingsService {}
class _MockCloudRuntimeProvider extends Mock implements CloudRuntimeProvider {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const InferenceRequest(
        sessionId: 'fallback',
        prompt: 'fallback',
      ),
    );
  });

  late _MockExecutionEngine executor;
  late _MockInferenceService inference;
  late _MockWebSearchTool webSearch;
  late _MockRuntimeSettings settings;
  late _MockCloudRuntimeProvider cloud;

  setUp(() {
    executor = _MockExecutionEngine();
    inference = _MockInferenceService();
    webSearch = _MockWebSearchTool();
    settings = _MockRuntimeSettings();
    cloud = _MockCloudRuntimeProvider();

    when(() => inference.stream(any())).thenAnswer(
      (_) => Stream<InferenceResponse>.value(
        InferenceResponse.finalChunk(
          text: 'ok',
          tokensGenerated: 1,
          model: 'test',
        ),
      ),
    );
  });

  AssistantWebAwareOrchestrator build() {
    return AssistantWebAwareOrchestrator(
      intentAnalyzer: const IntentAnalyzer(),
      executor: executor,
      inferenceService: inference,
      webSearchTool: webSearch,
      runtimeSettingsService: settings,
      cloudRuntimeProvider: cloud,
    );
  }

  test('enriches time-sensitive Hybrid chat when Hannibal will use Cloud',
      () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.hybrid);
    when(() => cloud.shouldPreferCloudFor(any())).thenReturn(true);
    when(
      () => cloud.recommendProviderFor(
        any(),
        enforceAutomaticPolicy: true,
      ),
    ).thenReturn('gemini');
    when(() => webSearch.execute(any())).thenAnswer(
      (_) async => const ToolResult(
        toolId: 'web_search',
        output: 'Paris weather\nURL: https://example.test/weather',
      ),
    );

    final chunks = await build()
        .handleStream(
          'Che meteo fa oggi a Parigi?',
          sessionId: 'hybrid-web',
          systemPrompt: 'Base prompt.',
        )
        .toList();

    expect(chunks.single.text, 'ok');
    verify(() => webSearch.execute(any())).called(1);

    final captured = verify(() => inference.stream(captureAny())).captured;
    expect(captured, hasLength(1));
    final request = captured.single as InferenceRequest;
    expect(request.systemPrompt, contains('Base prompt.'));
    expect(request.systemPrompt, contains('[WEB SEARCH RESULTS]'));
    expect(request.systemPrompt, contains('https://example.test/weather'));
    expect(request.cloudProviderId, 'gemini');
  });

  test('Hybrid web failure degrades to the original inference request',
      () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.hybrid);
    when(() => cloud.shouldPreferCloudFor(any())).thenReturn(true);
    when(
      () => cloud.recommendProviderFor(
        any(),
        enforceAutomaticPolicy: true,
      ),
    ).thenReturn('gemini');
    when(() => webSearch.execute(any())).thenAnswer(
      (_) async => const ToolResult(
        toolId: 'web_search',
        output: '',
        success: false,
        error: 'network unavailable',
      ),
    );

    final chunks = await build()
        .handleStream(
          'Qual è il prezzo attuale di questo prodotto?',
          sessionId: 'hybrid-offline-fallback',
          systemPrompt: 'Base prompt.',
        )
        .toList();

    expect(chunks.single.text, 'ok');
    verify(() => webSearch.execute(any())).called(1);

    final request = verify(() => inference.stream(captureAny())).captured.single
        as InferenceRequest;
    expect(request.systemPrompt, 'Base prompt.');
  });

  test('does not pre-search Local mode', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);

    final chunks = await build()
        .handleStream(
          'Che meteo fa oggi a Parigi?',
          sessionId: 'local-web',
        )
        .toList();

    expect(chunks.single.text, 'ok');
    verifyNever(() => webSearch.execute(any()));
  });

  test('does not pre-search ordinary Hybrid conversation', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.hybrid);
    when(() => cloud.shouldPreferCloudFor(any())).thenReturn(true);
    when(
      () => cloud.recommendProviderFor(
        any(),
        enforceAutomaticPolicy: true,
      ),
    ).thenReturn('gemini');

    final chunks = await build()
        .handleStream(
          'Spiegami la fotosintesi.',
          sessionId: 'ordinary-chat',
        )
        .toList();

    expect(chunks.single.text, 'ok');
    verifyNever(() => webSearch.execute(any()));
  });
}
