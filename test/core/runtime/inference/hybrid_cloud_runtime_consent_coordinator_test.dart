import 'dart:async';
import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_local_identity.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_runtime_consent_coordinator.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_runtime_source_evidence.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final class _ProtectedMemory implements HybridCloudConsentStorage {
  final contents = <String, String>{};
  @override
  Future<String?> read(String key) async => contents[key];
  @override
  Future<void> write(String key, String value) async { contents[key] = value; }
  @override
  Future<void> delete(String key) async { contents.remove(key); }
}

final class _Secrets implements CloudSecretStorage {
  final contents = <String, String>{};
  @override
  Future<String?> read(String key) async => contents[key];
  @override
  Future<void> write(String key, String value) async { contents[key] = value; }
  @override
  Future<void> delete(String key) async { contents.remove(key); }
}

CloudRuntimeProvider _runtime(HybridCloudRuntimeConsentCoordinator coordinator,
    {void Function()? onLegacy}) => CloudRuntimeProvider(
  consentGated: true,
  sendQuery: (_, __) async {
    onLegacy?.call();
    throw StateError('Legacy callback MUST NOT send Cloud data');
  },
  consentGatedSend: coordinator.send,
  supportedProviders: () => const <String>['openAi', 'gemini'],
  isProviderAvailable: (_) => true,
  providerDisplayName: ([name]) => name ?? 'Cloud',
  automaticUseAllowed: (_) => true,
  modelForProvider: (_) => 'gpt-test',
);

void main() {
  const input = InferenceRequest(
    sessionId: 'chat-1', prompt: 'Current private question',
    systemPrompt: 'System instructions',
    context: <ChatTurn>[
      ChatTurn(role: ChatRole.user, content: 'Earlier personal question'),
    ],
    routeDirective: InferenceRouteDirective.cloudOnly,
    cloudProviderId: 'openAi',
  );
  const evidence = <AiMessage>[
    AiMessage(role: AiMessageRole.user, content: 'Earlier personal question'),
  ];

  test('runtime -> trusted Chat evidence -> real review -> one-use HTTP',
      () async {
    final protected = _ProtectedMemory();
    final identity = HybridCloudLocalIdentity(storage: protected);
    final consent = HybridCloudDisclosureConsent(
      backend: protected,
      authorizeOwnerSession: identity.isAuthorized,
    );
    final credentials = CloudCredentialStore(storage: _Secrets());
    await credentials.initialize();
    await credentials.setApiKey('openAi', 'test-only', accountId: 'account-1');

    var reviews = 0, httpSends = 0, legacySends = 0;
    final client = MockClient((request) async {
      httpSends++;
      expect(request.url.host, contains('openai'));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['max_tokens'], 2048);
      expect(body['messages'], hasLength(3));
      expect((body['messages'] as List<dynamic>).last['content'],
          'Current private question');
      expect(request.headers['authorization'], 'Bearer test-only');
      return http.Response(jsonEncode(<String, dynamic>{
        'model': 'gpt-test',
        'choices': <dynamic>[<String, dynamic>{
          'message': <String, String>{'content': 'Approved result'},
          'finish_reason': 'stop',
        }],
        'usage': <String, int>{'total_tokens': 17},
      }), 200);
    });

    // This evidence comes from the typed InferenceRequest, as it will in
    // real Chat, rather than from an injected provider callback.
    final requestWithEvidence = input.copyWith(
      trustedCloudSourceEvidence: HybridCloudRuntimeSourceEvidence(
        sessionId: input.sessionId,
        originalQuestion: 'Current private question',
        baseSystemPrompt: 'System instructions',
        originalHistory: evidence,
      ),
    );
    final coordinator = HybridCloudRuntimeConsentCoordinator(
      consent: consent,
      identity: identity,
      credentials: credentials,
      client: client,
      requestConsent: (review) async {
        reviews++;
        expect(review.disclosure.accountId, 'account-1');
        expect(review.disclosure.outboundText,
            contains('Earlier personal question'));
        expect(review.disclosure.outboundText,
            contains('Current private question'));
        return <HybridDisclosureScope, HybridCloudConsentChoice>{
          for (final scope in review.needsConsent)
            scope: HybridCloudConsentChoice.allowOnce,
        };
      },
    );
    final runtime = _runtime(
      coordinator,
      onLegacy: () => legacySends++,
    );
    for (var i = 0; i < 2; i++) {
      final replies = await runtime.streamInference(
        request: requestWithEvidence, cancellationToken: CancellationToken(),
      ).toList();
      expect(replies.last.isError, isFalse);
      expect(replies.last.text, 'Approved result');
    }
    expect(reviews, 2);
    expect(httpSends, 2);
    expect(legacySends, 0);
    client.close();
  });

  test('missing source evidence or dialog refuses request without HTTP',
      () async {
    final protected = _ProtectedMemory();
    final identity = HybridCloudLocalIdentity(storage: protected);
    final consent = HybridCloudDisclosureConsent(
      backend: protected,
      authorizeOwnerSession: identity.isAuthorized,
    );
    final credentials = CloudCredentialStore(storage: _Secrets());
    await credentials.initialize();
    await credentials.setApiKey('openAi', 'test-only', accountId: 'account-1');
    var httpSends = 0, legacySends = 0;
    final client = MockClient((_) async {
      httpSends++;
      return http.Response('unexpected', 200);
    });

    final noEvidence = _runtime(HybridCloudRuntimeConsentCoordinator(
      consent: consent, identity: identity, credentials: credentials,
      client: client,
      evidenceFor: (_) async => null,
      requestConsent: (_) async => throw StateError('Unexpected dialog'),
    ), onLegacy: () => legacySends++);
    final missing = await noEvidence.streamInference(
      request: input, cancellationToken: CancellationToken(),
    ).toList();
    expect(missing.last.isError, isTrue);

    final noDialog = _runtime(HybridCloudRuntimeConsentCoordinator(
      consent: consent, identity: identity, credentials: credentials,
      client: client,
      evidenceFor: (source) async => HybridCloudRuntimeSourceEvidence(
        sessionId: source.sessionId,
        originalQuestion: 'Current private question',
        baseSystemPrompt: 'System instructions',
        originalHistory: evidence,
      ),
    ), onLegacy: () => legacySends++);
    final refused = await noDialog.streamInference(
      request: input, cancellationToken: CancellationToken(),
    ).toList();
    expect(refused.last.isError, isTrue);
    expect(httpSends, 0);
    expect(legacySends, 0);
    client.close();
  });

  test('cancelling while review is visible prevents grants and HTTP',
      () async {
    final protected = _ProtectedMemory();
    final identity = HybridCloudLocalIdentity(storage: protected);
    final consent = HybridCloudDisclosureConsent(
      backend: protected,
      authorizeOwnerSession: identity.isAuthorized,
    );
    final credentials = CloudCredentialStore(storage: _Secrets());
    await credentials.initialize();
    await credentials.setApiKey('openAi', 'test-only', accountId: 'account-1');
    var httpSends = 0;
    final client = MockClient((_) async {
      httpSends++;
      return http.Response('unexpected', 200);
    });
    final shown = Completer<HybridCloudConsentReview>();
    final decision = Completer<
        Map<HybridDisclosureScope, HybridCloudConsentChoice>>();
    final coordinator = HybridCloudRuntimeConsentCoordinator(
      consent: consent, identity: identity, credentials: credentials,
      client: client,
      evidenceFor: (source) async => HybridCloudRuntimeSourceEvidence(
        sessionId: source.sessionId,
        originalQuestion: 'Current private question',
        baseSystemPrompt: 'System instructions',
        originalHistory: evidence,
      ),
      requestConsent: (review) {
        shown.complete(review);
        return decision.future;
      },
    );
    final token = CancellationToken();
    final stream = _runtime(coordinator).streamInference(
      request: input, cancellationToken: token,
    ).toList();
    final review = await shown.future;
    token.cancel();
    decision.complete(<HybridDisclosureScope, HybridCloudConsentChoice>{
      for (final scope in review.needsConsent)
        scope: scope.sensitivity ==
                HybridDisclosureSensitivity.publicOrNonPersonal
            ? HybridCloudConsentChoice.allowAlways
            : HybridCloudConsentChoice.allowOnce,
    });
    final chunks = await stream;
    expect(chunks.last.isError, isTrue);
    expect(httpSends, 0);
    expect(protected.contents.keys.where(
        (k) => k.startsWith('hybrid_cloud_consent_v3_')), isEmpty);
    client.close();
  });

  test('unbound credential and substituted history reject before review',
      () async {
    final protected = _ProtectedMemory();
    final identity = HybridCloudLocalIdentity(storage: protected);
    final consent = HybridCloudDisclosureConsent(
      backend: protected,
      authorizeOwnerSession: identity.isAuthorized,
    );
    final credentials = CloudCredentialStore(storage: _Secrets());
    await credentials.initialize();
    var reviews = 0, httpSends = 0;
    final client = MockClient((_) async {
      httpSends++;
      return http.Response('unexpected', 200);
    });
    final coordinator = HybridCloudRuntimeConsentCoordinator(
      consent: consent, identity: identity, credentials: credentials,
      client: client,
      evidenceFor: (source) async => HybridCloudRuntimeSourceEvidence(
        sessionId: source.sessionId,
        originalQuestion: 'Current private question',
        baseSystemPrompt: 'System instructions',
        originalHistory: const <AiMessage>[
          AiMessage(role: AiMessageRole.assistant,
              content: 'Earlier personal question'),
        ],
      ),
      requestConsent: (_) async {
        reviews++;
        return <HybridDisclosureScope, HybridCloudConsentChoice>{};
      },
    );
    final first = await _runtime(coordinator).streamInference(
      request: input, cancellationToken: CancellationToken(),
    ).toList();
    expect(first.last.isError, isTrue);
    await credentials.setApiKey('openAi', 'test-only',
        accountId: 'account-1');
    final second = await _runtime(coordinator).streamInference(
      request: input, cancellationToken: CancellationToken(),
    ).toList();
    expect(second.last.isError, isTrue);
    expect(reviews, 0);
    expect(httpSends, 0);
    client.close();
  });
}
