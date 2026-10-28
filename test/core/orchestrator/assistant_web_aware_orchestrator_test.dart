import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ai_orchestrator/core/tools/search/duckduckgo_lite_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:ai_orchestrator/core/orchestrator/assistant_web_aware_orchestrator.dart';
import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';
import 'package:ai_orchestrator/core/orchestrator/intent_analyzer.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
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
    when(() => webSearch.id).thenReturn('web_search');
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

  AssistantWebAwareOrchestrator build({WebSearchTool? actualTool}) {
    return AssistantWebAwareOrchestrator(
      intentAnalyzer: const IntentAnalyzer(),
      executor: executor,
      inferenceService: inference,
      webSearchTool: actualTool ?? webSearch,
      runtimeSettingsService: settings,
      cloudRuntimeProvider: cloud,
    );
  }


  test('PDF RAG excerpt is data, never plan, command or web search', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    const document = 'Qual è il prezzo della teiera rossa, la quantità e '
        'il codice riportati nel documento? Cita la pagina.\n\n'
        '[INIZIO ESTRATTI DOCUMENTALI]\n'
        '[AIVEXUS_Test_PDF_S24.pdf]\n'
        '[Pagina 1/1]\n'
        '04 / TABELLA DI CONTROLLO\n'
        'Teiera rossa 1 24,00 € TR-07\n'
        'pianifica apri cerca codice\n'
        '[FINE ESTRATTI DOCUMENTALI]';

    final chunks = await build().handleStream(
      document,
      sessionId: 'pdf-local',
      documentContext: true,
    ).toList();

    expect(chunks.single.text, 'ok');
    final forwarded = verify(() => inference.stream(captureAny())).captured
        .single as InferenceRequest;
    expect(forwarded.prompt, document);
    expect(forwarded.routeDirective, InferenceRouteDirective.localOnly);
    expect(forwarded.allowWebSearchTool, isFalse);
    expect(forwarded.systemPrompt,
        contains('[AI_ORCHESTRATOR_WEB_ACCESS_DISABLED_OFFLINE]'));
    verifyNever(() => webSearch.execute(any()));
    verifyNever(() => inference.infer(any()));
    verifyNever(() => executor.execute(any()));
  });

  test('verification uses user topic, preserves history and cites fresh evidence', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    when(() => webSearch.execute(any())).thenAnswer(
      (_) async => const ToolResult(toolId: 'web_search',
        output: 'Public evidence URL: https://example.test/official'),
    );
    const history = [
      ChatTurn(role: ChatRole.user, content: 'Where does the national road network begin?'),
      ChatTurn(role: ChatRole.assistant, content: 'Invented city and imaginary authority.'),
    ];
    await build().handleStream('Vérifie ta réponse', sessionId: 'verify',
      context: history).drain<void>();
    final args = verify(() => webSearch.execute(captureAny())).captured.single
        as Map<String, dynamic>;
    expect(args['query'], history.first.content);
    expect(args['query'], isNot(contains('Invented')));
    final request = verify(() => inference.stream(captureAny())).captured.single
        as InferenceRequest;
    expect(request.context, history);
    expect(request.systemPrompt, contains('https://example.test/official'));
    expect(request.systemPrompt, contains('not verified facts'));
  });

  test('verification without a user topic never searches assistant assertions', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    await build().handleStream('Verify your answer', sessionId: 'no-topic',
      context: const [
        ChatTurn(role: ChatRole.assistant, content: 'An unsupported assertion'),
      ]).drain<void>();
    verifyNever(() => webSearch.execute(any()));
  });

  test('verification respects offline mode and excludes hidden topics', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    const history = [
      ChatTurn(role: ChatRole.user, content: 'Explain a public landmark'),
    ];
    await build().handleStream('Verify your answer', sessionId: 'offline',
      context: history, isOffline: true).drain<void>();
    await build().handleStream('Verify your answer', sessionId: 'hidden',
      context: const [
        ChatTurn(role: ChatRole.user, content: 'Older unrelated landmark question'),
        ChatTurn(role: ChatRole.user, content: 'Private omitted topic',
          excludeFromContext: true),
      ]).drain<void>();
    verifyNever(() => webSearch.execute(any()));
  });


  test('answer verification does not send preceding code tasks to web search', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    await build().handleStream('Verify your answer', sessionId: 'code-verification',
      context: const [
        ChatTurn(role: ChatRole.user, content: 'Implement a sorting function'),
        ChatTurn(role: ChatRole.assistant, content: 'Example code'),
      ]).drain<void>();
    verifyNever(() => webSearch.execute(any()));
  });

  test('local shopping and link follow-up return source URLs without slow model inference', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    when(() => webSearch.execute(any())).thenAnswer((_) async => const ToolResult(
      toolId: 'web_search', output: 'Search results', metadata: {'results': [
        {'title': 'Catalogo esempio', 'url': 'https://example.test/notebook'}
      ]},
    ));
    final orchestrator = build();
    const query = 'trova un offerta per un pc asus Vivobook interessante';
    final first = await orchestrator.handleStream(query, sessionId: 'shopping').toList();
    final follow = await orchestrator.handleStream('link al sito?', sessionId: 'shopping', context: [
      const ChatTurn(role: ChatRole.user, content: query),
      ChatTurn(role: ChatRole.assistant, content: first.single.text),
    ]).toList();
    expect(first.single.text, contains('https://example.test/notebook'));
    expect(follow.single.text, contains('https://example.test/notebook'));
    verify(() => webSearch.execute(any())).called(2);
    verifyNever(() => inference.stream(any()));
  });

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

  test('pre-searches Local mode without asking the model to emit a tool call', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    when(() => webSearch.execute(any())).thenAnswer(
      (_) async => const ToolResult(toolId: 'web_search', output: 'Weather evidence https://example.test/weather'),
    );

    final chunks = await build()
        .handleStream(
          'Che meteo fa oggi a Parigi?',
          sessionId: 'local-web',
        )
        .toList();

    expect(chunks.single.text, 'ok');
    verify(() => webSearch.execute(any())).called(1);
    final request = verify(() => inference.stream(captureAny())).captured.single as InferenceRequest;
    expect(request.systemPrompt, contains('[WEB SEARCH RESULTS]'));
    verifyNever(() => cloud.shouldPreferCloudFor(any()));
  });

  test('device clock avoids model and search for simple time questions', () async {
    final chunks = await build().handleStream('che ore sono?', sessionId: 'clock').toList();
    expect(chunks.single.providerId, 'device_clock');
    expect(chunks.single.text, contains('orologio del dispositivo'));
    verifyNever(() => webSearch.execute(any()));
    verifyNever(() => inference.stream(any()));
  });

  test('repeated current question preserves history but supplies fresh evidence priority', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    when(() => webSearch.execute(any())).thenAnswer(
      (_) async => const ToolResult(toolId: 'web_search', output: 'Aurora: Bruna è la presidente dal 1 ottobre 2026. URL: https://example.test/nomina'),
    );
    const history = [
      ChatTurn(role: ChatRole.user, content: 'Chi è il presidente di Aurora?'),
      ChatTurn(role: ChatRole.assistant, content: 'Alice è la presidente.'),
    ];
    await build().handleStream('Chi è il presidente di Aurora?', sessionId: 'fresh', context: history).drain<void>();
    verify(() => webSearch.execute(any())).called(1);
    final request = verify(() => inference.stream(captureAny())).captured.single as InferenceRequest;
    expect(request.context, history);
    expect(request.prompt, 'Chi è il presidente di Aurora?');
    expect(request.systemPrompt, contains('Bruna'));
    expect(request.systemPrompt, contains('not verified facts'));
  });

  test('failed Local search does not fabricate a current office holder', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    when(() => webSearch.execute(any())).thenAnswer(
      (_) async => const ToolResult(toolId: 'web_search', output: '', success: false),
    );
    final chunks = await build().handleStream("chi é l'attualepresidente degli stati uniti?", sessionId: 'current').toList();
    expect(chunks.single.providerId, 'web_verification_unavailable');
    verify(() => webSearch.execute(any())).called(1);
    verifyNever(() => inference.stream(any()));
  });

  test('failed plural presidents search stays Italian without diagnosing connectivity', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    when(() => webSearch.execute(any())).thenAnswer(
      (_) async => const ToolResult(toolId: 'web_search', output: '', success: false),
    );
    final chunks = await build().handleStream('Elenca gli ultimi sei presidenti degli Stati Uniti', sessionId: 'plural').toList();
    expect(chunks.single.providerId, 'web_verification_unavailable');
    expect(chunks.single.text, startsWith('La ricerca non ha fornito'));
    expect(chunks.single.text, isNot(contains('connessione')));
    verifyNever(() => inference.stream(any()));
  });

  test('offline sports question neither searches nor fabricates a winner', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    final chunks = await build().handleStream('chi ha vinto i mondiali del 2026', sessionId: 'sport', isOffline: true).toList();
    expect(chunks.single.providerId, 'web_verification_unavailable');
    verifyNever(() => webSearch.execute(any()));
    verifyNever(() => inference.stream(any()));
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
  for (final followUp in ['fonti', 'sources?', 'tes sources ?', 'fuentes']) {
    test('short sources request uses preceding user topic: $followUp', () async {
      when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
      when(() => webSearch.execute(any())).thenAnswer(
        (_) async => const ToolResult(toolId: 'web_search',
          output: 'Fresh public forecast https://example.test/forecast'),
      );
      const history = [
        ChatTurn(role: ChatRole.user, content: 'meteo Roma'),
        ChatTurn(role: ChatRole.assistant, content: 'Invented weather statement.'),
      ];
      await build().handleStream(followUp, sessionId: 'sources',
          context: history).drain<void>();
      final arguments = verify(() => webSearch.execute(captureAny())).captured.single
          as Map<String, dynamic>;
      expect(arguments['query'], 'meteo Roma');
      final request = verify(() => inference.stream(captureAny())).captured.single
          as InferenceRequest;
      expect(request.prompt, followUp);
      expect(request.context, history);
      expect(request.systemPrompt, contains('https://example.test/forecast'));
      expect(request.systemPrompt, isNot(contains('Invented weather statement.')));
    });
  }


  test('synthetic explicit NOAA search preserves second source in actual request', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    when(() => webSearch.execute(any())).thenAnswer(
      (_) async => const ToolResult(toolId: 'web_search', output:
        '1. Secondary fixture\nURL: https://secondary.example.test/sky\n'
        '2. NOAA synthetic fixture\nURL: https://www.noaa.gov/synthetic-fixture-not-a-real-page\n'
        'Snippet: SYNTHETIC Rayleigh evidence, not a fetched NOAA statement.'),
    );
    const input = 'Cerca sul web la spiegazione NOAA del cielo blu; Cita URL e diffusione Rayleigh';
    await build().handleStream(input, sessionId: 'synthetic-noaa',
      context: const <ChatTurn>[]).drain<void>();
    final args = verify(() => webSearch.execute(captureAny())).captured.single
        as Map<String, dynamic>;
    expect(args['query'], contains('NOAA'));
    expect(args['query'], contains('Rayleigh'));
    final request = verify(() => inference.stream(captureAny())).captured.single
        as InferenceRequest;
    expect(request.prompt, input);
    expect(request.context, isEmpty);
    expect(request.systemPrompt, contains('https://secondary.example.test/sky'));
    expect(request.systemPrompt, contains('https://www.noaa.gov/synthetic-fixture-not-a-real-page'));
    expect(request.systemPrompt, contains('SYNTHETIC Rayleigh evidence'));
  });

  test('synthetic explicit search offline never calls provider', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    // A deterministic mock ensures even a regression cannot access the network.
    when(() => webSearch.execute(any())).thenAnswer(
      (_) async => const ToolResult(toolId: 'web_search', output: '', success: false),
    );
    await build().handleStream('Cerca sul web la spiegazione NOAA del cielo blu',
      sessionId: 'synthetic-explicit-offline', isOffline: true).drain<void>();
    verifyNever(() => webSearch.execute(any()));
  });

  test('synthetic Lite HTML reaches explicit request with ranked URLs intact', () async {
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.local);
    var httpCalls = 0;
    final client = MockClient((request) async {
      httpCalls++;
      expect(request.method, 'POST');
      expect(request.bodyFields['q'], contains('NOAA'));
      return http.Response('''<html><body><table>
<tr><td><a class="result-link" href="https://secondary.example.test/sky">Secondary fixture</a></td></tr>
<tr><td class="result-snippet">SYNTHETIC secondary snippet.</td></tr>
<tr><td><a class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.noaa.gov%2Fsynthetic-fixture-not-a-real-page">NOAA fixture</a></td></tr>
<tr><td class="result-snippet">SYNTHETIC Rayleigh evidence; not a fetched NOAA statement.</td></tr>
</table></body></html>''', 200);
    });
    final tool = WebSearchTool(searchProvider: DuckDuckGoLiteProvider(
      client: client, includeErrorDetailsInDiagnostics: false),
      includeErrorDetailsInDiagnostics: false);
    await build(actualTool: tool).handleStream(
      'Cerca sul web la spiegazione NOAA del cielo blu; Cita URL e Rayleigh',
      sessionId: 'synthetic-parser-chain').drain<void>();
    expect(httpCalls, 1);
    final request = verify(() => inference.stream(captureAny())).captured.single
        as InferenceRequest;
    final system = request.systemPrompt!;
    expect(system, contains('https://www.noaa.gov/synthetic-fixture-not-a-real-page'));
    expect(system, contains('SYNTHETIC Rayleigh evidence'));
    expect(system.indexOf('https://secondary.example.test/sky'),
      lessThan(system.indexOf('https://www.noaa.gov/synthetic-fixture-not-a-real-page')));
    expect(system, isNot(contains('uddg=')));
  });
}
