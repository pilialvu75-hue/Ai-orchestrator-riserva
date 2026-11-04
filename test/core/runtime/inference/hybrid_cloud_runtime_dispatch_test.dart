import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_ai_request_seal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_approved_completion_sender.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_consent_denied.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_native_request_projection.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final class _ConsentStore implements HybridCloudConsentStorage {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async { map[key] = value; }
  @override
  Future<void> delete(String key) async { map.remove(key); }
}
final class _CredentialStore implements CloudSecretStorage {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async { map[key] = value; }
  @override
  Future<void> delete(String key) async { map.remove(key); }
}

void main() {
  const question = HybridDisclosureScope(
    HybridDisclosureOrigin.currentQuestion,
    HybridDisclosureSensitivity.personal,
  );
  const sys = HybridDisclosureScope(
    HybridDisclosureOrigin.systemInstructions,
    HybridDisclosureSensitivity.unknown,
  );
  const history = HybridDisclosureScope(
    HybridDisclosureOrigin.conversationHistory,
    HybridDisclosureSensitivity.unknown,
  );
  const controls = HybridDisclosureScope(
    HybridDisclosureOrigin.systemInstructions,
    HybridDisclosureSensitivity.publicOrNonPersonal,
  );

  test('runtime projection strips only known nontransport metadata'
      ' and reviews effective 2048 token budget', () {
    final src = AiRequest(
      providerId: 'openAi', modelId: 'gpt-test',
      prompt: 'Private question', systemPrompt: 'Rules',
      maxTokens: 512, metadata: const <String, dynamic>{
        'sessionId': 'local-chat', 'requestId': 'req-1',
      },
    );
    final projected = HybridCloudNativeRequestProjection.project(src);
    expect(projected.metadata, isEmpty);
    expect(projected.maxTokens, 2048);
    expect(projected.prompt, 'Private question');
    expect(() => HybridCloudNativeRequestProjection.project(
      const AiRequest(
        providerId: 'openAi', modelId: 'gpt-test', prompt: 'p',
        metadata: <String, dynamic>{'hidden': 'private'},
      ),
    ), throwsStateError);
    expect(() => HybridCloudNativeRequestProjection.project(
      const AiRequest(
        providerId: 'openAi', modelId: 'gpt-test', prompt: 'p',
        tools: <Map<String, dynamic>>[<String, dynamic>{'secret': 'x'}],
      ),
    ), throwsStateError);
    expect(() => HybridCloudNativeRequestProjection.project(
      const AiRequest(providerId: 'claude', prompt: 'p'),
    ), throwsStateError);
  });

  test('real CloudRuntimeProvider request -> reviewed HTTP -> AiResponse'
      ' with consent review on every repeat (no cache)', () async {
    final creds = CloudCredentialStore(storage: _CredentialStore());
    await creds.initialize();
    await creds.setApiKey('openAi', 'dummy', accountId: 'acc-1');
    final consent = HybridCloudDisclosureConsent(
      backend: _ConsentStore(),
      authorizeOwnerSession: (owner, session) async =>
          owner == 'owner-a' && session == 'local-session',
    );
    var httpSends = 0;
    var reviews = 0;
    final client = MockClient((http.Request request) async {
      httpSends++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['max_tokens'], 2048);
      expect(body['messages'], hasLength(3));
      expect(body['metadata'], isNull);
      expect((body['messages'] as List<dynamic>).last['content'],
          'Current private question');
      return http.Response(jsonEncode(<String, dynamic>{
        'model': 'gpt-test',
        'choices': <dynamic>[<String, dynamic>{
          'message': <String, String>{'content': 'Approved answer'},
          'finish_reason': 'stop',
        }],
        'usage': <String, int>{'total_tokens': 18},
      }), 200);
    });
    final completion = HybridCloudApprovedCompletionSender(
      consent: consent, credentials: creds, client: client,
    );
    final runtime = CloudRuntimeProvider(
      consentGated: true,
      supportedProviders: () => const <String>['openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'OpenAI',
      automaticUseAllowed: (_) => true,
      modelForProvider: (_) => 'gpt-test',
      sendQuery: (_, __) => throw StateError(
        'Legacy Cloud callback must never run with consentGated=true',
      ),
      consentGatedSend: (source, incoming, token) async {
        expect(token.isCancelled, isFalse);
        expect(source.prompt, 'Current private question');
        final projected = HybridCloudNativeRequestProjection.project(incoming);
        final seal = HybridCloudAiRequestSeal.fromRequest(
          ownerId: 'owner-a', sessionId: 'local-session',
          accountId: 'acc-1', purpose: 'Review private history and question',
          request: projected, controlScope: controls,
          promptSegments: <HybridDisclosureSegment>[
            HybridDisclosureSegment(text: projected.prompt, scope: question),
          ],
          systemPromptSegments: <HybridDisclosureSegment>[
            HybridDisclosureSegment(text: projected.systemPrompt!, scope: sys),
          ],
          historyScopes: <HybridDisclosureScope>[
            for (final _ in projected.messages) history,
          ],
        );
        final permit = await consent.authorizeForDispatch(
          disclosure: seal.disclosure,
          requestConsent: (review) async {
            reviews++;
            expect(review.disclosure.outboundText,
                contains('Older private question'));
            return <HybridDisclosureScope, HybridCloudConsentChoice>{
              for (final scope in review.needsConsent)
                scope: HybridCloudConsentChoice.allowOnce,
            };
          },
        );
        if (permit == null) throw const HybridCloudConsentDenied();
        return completion.complete(
          seal: seal, permit: permit,
          expectedCredentialSecret: 'dummy',
        );
      },
    );
    const input = InferenceRequest(
      sessionId: 'chat-1', prompt: 'Current private question',
      systemPrompt: 'System rules',
      context: <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'Older private question'),
      ],
      routeDirective: InferenceRouteDirective.cloudOnly,
      cloudProviderId: 'openAi',
    );
    for (var i = 0; i < 2; i++) {
      final result = await runtime.streamInference(
        request: input, cancellationToken: CancellationToken(),
      ).toList();
      expect(result.last.isError, isFalse);
      expect(result.last.text, 'Approved answer');
      expect(result.last.tokensGenerated, 18);
    }
    expect(reviews, 2);
    expect(httpSends, 2);
    client.close();
  });

  test('denied consent blocks provider failover even when enabled', () async {
    var callbacks = 0;
    var legacyCallbacks = 0;
    final runtime = CloudRuntimeProvider(
      consentGated: true,
      sendQuery: (_, __) async {
        legacyCallbacks++;
        throw StateError('Legacy provider callback invoked');
      },
      consentGatedSend: (_, __, token) async {
        callbacks++;
        throw const HybridCloudConsentDenied();
      },
      supportedProviders: () => const <String>['openAi', 'gemini'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'Cloud',
      automaticUseAllowed: (_) => true,
    );
    final result = await runtime.streamInference(
      request: const InferenceRequest(
        sessionId: 's', prompt: 'Private question',
        routeDirective: InferenceRouteDirective.cloudOnly,
        allowCloudProviderFailover: true,
      ),
      cancellationToken: CancellationToken(),
    ).toList();
    expect(callbacks, 1);
    expect(legacyCallbacks, 0);
    expect(result.last.isError, isTrue);
    expect(result.last.errorMessage, 'Cloud disclosure was not approved.');
  });

  test('consentGated with no gate never calls legacy Cloud transport',
      () async {
    var sends = 0;
    final runtime = CloudRuntimeProvider(
      consentGated: true,
      sendQuery: (_, __) async {
        sends++;
        throw StateError('Legacy Cloud must never be called');
      },
      supportedProviders: () => const <String>['openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'OpenAI',
      automaticUseAllowed: (_) => true,
      modelForProvider: (_) => 'gpt-test',
    );
    final result = await runtime.streamInference(
      request: const InferenceRequest(
        sessionId: 'local-session',
        prompt: 'Private note',
        routeDirective: InferenceRouteDirective.cloudOnly,
      ),
      cancellationToken: CancellationToken(),
    ).toList();
    expect(sends, 0);
    expect(result.last.isError, isTrue);
    expect(result.last.errorMessage, contains('consent bridge not configured'));
  });

  test('consentGated transport error NEVER fails over to another Cloud',
      () async {
    var gatedSends = 0;
    var legacySends = 0;
    final runtime = CloudRuntimeProvider(
      consentGated: true,
      sendQuery: (_, __) async {
        legacySends++;
        throw StateError('Legacy provider callback invoked');
      },
      consentGatedSend: (request, outbound, token) async {
        gatedSends++;
        expect(request.prompt, 'Private note');
        expect(outbound.providerId, 'openAi');
        throw StateError('network or serializer failed');
      },
      supportedProviders: () => const <String>['openAi', 'gemini'],
      isProviderAvailable: (_) => true,
      preferredProvider: () => 'openAi',
      providerDisplayName: ([name]) => name ?? 'Cloud',
      automaticUseAllowed: (_) => true,
      modelForProvider: (_) => 'gpt-test',
    );
    final result = await runtime.streamInference(
      request: const InferenceRequest(
        sessionId: 'local-session',
        prompt: 'Private note',
        routeDirective: InferenceRouteDirective.cloudOnly,
        allowCloudProviderFailover: true,
      ),
      cancellationToken: CancellationToken(),
    ).toList();
    expect(gatedSends, 1);
    expect(legacySends, 0);
    expect(result.last.isError, isTrue);
  });

  test('approval issued before cancellation cannot start native HTTP',
      () async {
    final creds = CloudCredentialStore(storage: _CredentialStore());
    await creds.initialize();
    await creds.setApiKey('openAi', 'test-only', accountId: 'account-1');
    final consent = HybridCloudDisclosureConsent(
      backend: _ConsentStore(),
      authorizeOwnerSession: (o, s) async => o == 'owner' && s == 'session',
    );
    final seal = HybridCloudAiRequestSeal.fromRequest(
      ownerId: 'owner', sessionId: 'session',
      accountId: 'account-1', purpose: 'Answer private question',
      request: const AiRequest(
        providerId: 'openAi', modelId: 'gpt-test',
        prompt: 'Private prompt', maxTokens: 1024,
      ),
      controlScope: controls,
      promptSegments: const <HybridDisclosureSegment>[
        HybridDisclosureSegment(text: 'Private prompt', scope: question),
      ],
      historyScopes: const <HybridDisclosureScope>[],
    );
    final permit = await consent.authorizeForDispatch(
      disclosure: seal.disclosure,
      requestConsent: (review) async =>
          <HybridDisclosureScope, HybridCloudConsentChoice>{
            for (final scope in review.needsConsent)
              scope: HybridCloudConsentChoice.allowOnce,
          },
    );
    expect(permit, isNotNull);
    var httpSends = 0;
    final client = MockClient((_) async {
      httpSends++;
      return http.Response('unexpected', 200);
    });
    final token = CancellationToken()..cancel();
    final sender = HybridCloudApprovedCompletionSender(
      consent: consent, credentials: creds, client: client,
    );
    await expectLater(
      sender.complete(
        seal: seal, permit: permit!, cancellationToken: token,
        expectedCredentialSecret: 'test-only',
      ),
      throwsA(isA<StateError>()),
    );
    expect(httpSends, 0);
    client.close();
  });

  test('approved HTTP failure never echoes provider response body', () async {
    final creds = CloudCredentialStore(storage: _CredentialStore());
    await creds.initialize();
    await creds.setApiKey('gemini', 'dummy', accountId: 'acc');
    final consent = HybridCloudDisclosureConsent(
      backend: _ConsentStore(),
      authorizeOwnerSession: (o, s) async => o == 'owner' && s == 'session',
    );
    final seal = HybridCloudAiRequestSeal.fromRequest(
      ownerId: 'owner', sessionId: 'session',
      accountId: 'acc', purpose: 'Test private error',
      request: const AiRequest(
        providerId: 'gemini', modelId: 'gemini-test',
        prompt: 'Private prompt', maxTokens: 1024,
      ),
      controlScope: controls,
      promptSegments: const <HybridDisclosureSegment>[
        HybridDisclosureSegment(text: 'Private prompt', scope: question),
      ],
      historyScopes: const <HybridDisclosureScope>[],
    );
    final permit = await consent.authorizeForDispatch(
      disclosure: seal.disclosure,
      requestConsent: (review) async =>
          <HybridDisclosureScope, HybridCloudConsentChoice>{
            for (final scope in review.needsConsent)
              scope: HybridCloudConsentChoice.allowOnce,
          },
    );
    expect(permit, isNotNull);
    final sender = HybridCloudApprovedCompletionSender(
      consent: consent, credentials: creds,
      client: MockClient((_) async => http.Response(
        'PRIVATE BODY ECHO', 429,
        headers: <String, String>{'retry-after': '9'},
      )),
    );
    try {
      await sender.complete(
         seal: seal, permit: permit!, expectedCredentialSecret: 'dummy');
      fail('Expected HTTP exception');
    } on CloudHttpException catch (e) {
      expect(e.statusCode, 429);
      expect(e.retryAfter, const Duration(seconds: 9));
      expect(e.toString(), isNot(contains('PRIVATE BODY ECHO')));
    }
  });
}
