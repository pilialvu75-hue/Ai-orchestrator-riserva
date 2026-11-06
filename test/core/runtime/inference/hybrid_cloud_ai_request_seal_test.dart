import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_ai_request_seal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ProtectedMemory implements HybridCloudConsentStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  const controlScope = HybridDisclosureScope(
    HybridDisclosureOrigin.systemInstructions,
    HybridDisclosureSensitivity.publicOrNonPersonal,
  );
  const systemScope = HybridDisclosureScope(
    HybridDisclosureOrigin.systemInstructions,
    HybridDisclosureSensitivity.confidential,
  );
  const questionScope = HybridDisclosureScope(
    HybridDisclosureOrigin.currentQuestion,
    HybridDisclosureSensitivity.personal,
  );
  const ragScope = HybridDisclosureScope(
    HybridDisclosureOrigin.documentExcerpt,
    HybridDisclosureSensitivity.highlySensitive,
  );
  const historyScope = HybridDisclosureScope(
    HybridDisclosureOrigin.conversationHistory,
    HybridDisclosureSensitivity.personal,
  );
  final history = <AiMessage>[
    const AiMessage(role: AiMessageRole.user, content: 'My older question'),
    const AiMessage(role: AiMessageRole.assistant, content: 'Earlier answer'),
  ];

  AiRequest request({
    String prompt = 'Explain this: PRIVATE RAG',
    String system = 'System instructions',
    String model = 'model-alpha',
    String provider = 'gemini',
    List<AiMessage>? messages,
    List<Map<String, dynamic>> tools = const <Map<String, dynamic>>[],
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) => AiRequest(
        prompt: prompt,
        systemPrompt: system,
        providerId: provider,
        modelId: model,
        taskType: 'general',
        temperature: 0.4,
        maxTokens: 1024,
        messages: messages ?? history,
        tools: tools,
        metadata: metadata,
      );

  HybridCloudAiRequestSeal seal(
    AiRequest req, {
    String account = 'account-a',
    List<HybridDisclosureSegment>? prompts,
    List<HybridDisclosureScope>? scopes,
    List<HybridDisclosureSegment>? systems,
  }) => HybridCloudAiRequestSeal.fromRequest(
        ownerId: 'owner-a',
        sessionId: 'chat-a',
        accountId: account,
        purpose: 'Answer with approved context',
        request: req,
        controlScope: controlScope,
        systemPromptSegments: systems ??
            const <HybridDisclosureSegment>[
              HybridDisclosureSegment(
                text: 'System instructions',
                scope: systemScope,
              ),
            ],
        historyScopes: scopes ??
            const <HybridDisclosureScope>[historyScope, historyScope],
        promptSegments: prompts ??
            const <HybridDisclosureSegment>[
              HybridDisclosureSegment(
                text: 'Explain this: ',
                scope: questionScope,
              ),
              HybridDisclosureSegment(
                text: 'PRIVATE RAG',
                scope: ragScope,
              ),
            ],
      );

  test('seal covers controls, system prompt, history and document excerpt', () {
    final result = seal(request());
    final review = result.disclosure;
    expect(review.segments, hasLength(6));
    expect(review.outboundText, contains('PRIVATE RAG'));
    expect(review.outboundText, contains('Earlier answer'));
    expect(review.outboundText, contains('System instructions'));
    expect(review.outboundText, contains('model-alpha'));
    expect(review.outboundText, contains('general'));
    expect(review.scopes, contains(ragScope));
    expect(review.scopes, contains(historyScope));
    expect(review.scopes, contains(systemScope));
    expect(review.scopes, contains(questionScope));
  });

  test('unclassified system, history or prompt content fails closed', () {
    final req = request();
    expect(
      () => seal(req, systems: const <HybridDisclosureSegment>[]),
      throwsArgumentError,
    );
    expect(
      () => seal(req, scopes: const <HybridDisclosureScope>[historyScope]),
      throwsArgumentError,
    );
    expect(
      () => seal(req, prompts: const <HybridDisclosureSegment>[
        HybridDisclosureSegment(
          text: 'Explain this: ', scope: questionScope,
        ),
      ]),
      throwsArgumentError,
    );
  });

  test('tools and metadata cannot escape without classification', () {
    expect(
      () => seal(request(tools: const <Map<String, dynamic>>[
        <String, dynamic>{'name': 'search', 'private': 'secret'},
      ])),
      throwsArgumentError,
    );
    expect(
      () => seal(request(metadata: const <String, dynamic>{
        'hidden': 'private data',
      })),
      throwsArgumentError,
    );
    expect(
      () => seal(request(provider: 'openai')),
      returnsNormally,
    );
  });

  test('model or history change creates distinct review fingerprint', () {
    final a = seal(request());
    final b = seal(request(model: 'model-beta'));
    final c = seal(request(messages: <AiMessage>[
      const AiMessage(role: AiMessageRole.user, content: 'Different private history'),
      history[1],
    ]));
    expect(a.disclosure.contentFingerprint,
        isNot(b.disclosure.contentFingerprint));
    expect(a.disclosure.contentFingerprint,
        isNot(c.disclosure.contentFingerprint));
    expect(a.disclosure.contentFingerprint,
        isNot(seal(request(), account: 'account-b')
            .disclosure.contentFingerprint));
  });

  test('changing original history list after seal cannot alter approved request',
      () {
    final mutable = List<AiMessage>.from(history);
    final result = seal(request(messages: mutable));
    mutable[0] = const AiMessage(
      role: AiMessageRole.user, content: 'Unapproved new history',
    );
    expect(result.request.messages.first.content, 'My older question');
    expect(
      () => result.request.messages[0] = mutable[0],
      throwsUnsupportedError,
    );
  });

  test('permit authorizes only the sealed provider-neutral request', () async {
    final storage = _ProtectedMemory();
    final permissions = HybridCloudDisclosureConsent(
      backend: storage,
      authorizeOwnerSession: (owner, session) async =>
          owner == 'owner-a' && session == 'chat-a',
    );
    final approved = seal(request());
    final permit = await permissions.authorizeForDispatch(
      disclosure: approved.disclosure,
      requestConsent: (review) async => <HybridDisclosureScope, HybridCloudConsentChoice>{
        for (final scope in review.needsConsent)
          scope: HybridCloudConsentChoice.allowOnce,
      },
    );
    expect(permit, isNotNull);
    var sends = 0;
    final response = await approved.dispatch<String>(
      consent: permissions,
      permit: permit!,
      isCurrentDestination: (provider, account) async =>
          provider == 'gemini' && account == 'account-a',
      trustedSend: (exact) async {
        sends++;
        expect(exact.systemPrompt, 'System instructions');
        expect(exact.messages, hasLength(2));
        expect(exact.prompt, 'Explain this: PRIVATE RAG');
        expect(exact.tools, isEmpty);
        expect(exact.metadata, isEmpty);
        return 'ack';
      },
    );
    expect(response, 'ack');
    expect(sends, 1);
    await expectLater(
      approved.dispatch<String>(
        consent: permissions,
        permit: permit,
        isCurrentDestination: (_, __) async => true,
        trustedSend: (_) async {
          sends++;
          return 'duplicate';
        },
      ),
      throwsStateError,
    );
    expect(sends, 1);
  });

  test('reclassified RAG or changed destination never starts Cloud sender',
      () async {
    final storage = _ProtectedMemory();
    final permissions = HybridCloudDisclosureConsent(
      backend: storage,
      authorizeOwnerSession: (_, __) async => true,
    );
    final original = seal(request());
    final permit = (await permissions.authorizeForDispatch(
      disclosure: original.disclosure,
      requestConsent: (review) async => <HybridDisclosureScope, HybridCloudConsentChoice>{
        for (final scope in review.needsConsent)
          scope: HybridCloudConsentChoice.allowOnce,
      },
    ))!;
    final tampered = seal(request(), prompts: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'Explain this: ', scope: questionScope),
      HybridDisclosureSegment(text: 'PRIVATE RAG', scope: questionScope),
    ]);
    var calls = 0;
    await expectLater(
      tampered.dispatch<String>(
        consent: permissions,
        permit: permit,
        isCurrentDestination: (_, __) async => true,
        trustedSend: (_) async {
          calls++;
          return 'should not send';
        },
      ),
      throwsStateError,
    );
    expect(calls, 0);
  });
}
