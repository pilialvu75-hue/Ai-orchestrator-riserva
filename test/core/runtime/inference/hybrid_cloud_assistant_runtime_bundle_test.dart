import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_assistant_runtime_bundle.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_runtime_source_evidence.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final class _ConsentMemory implements HybridCloudConsentStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async { data[key] = value; }
  @override
  Future<void> delete(String key) async { data.remove(key); }
}

final class _Secrets implements CloudSecretStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async { data[key] = value; }
  @override
  Future<void> delete(String key) async { data.remove(key); }
}

void main() {
  const original = InferenceRequest(
    sessionId: 'real-chat-1',
    prompt: 'Sensitive current question',
    systemPrompt: 'System rules',
    context: <ChatTurn>[
      ChatTurn(role: ChatRole.user, content: 'Earlier private text'),
    ],
    routeDirective: InferenceRouteDirective.cloudOnly,
    cloudProviderId: 'openAi',
    allowCloudProviderFailover: false,
  );

  InferenceRequest authenticatedQuestion() => original.copyWith(
    trustedCloudSourceEvidence: HybridCloudRuntimeSourceEvidence(
      sessionId: original.sessionId,
      originalQuestion: original.prompt,
      baseSystemPrompt: original.systemPrompt!,
      originalHistory: const <AiMessage>[
        AiMessage(role: AiMessageRole.user, content: 'Earlier private text'),
      ],
    ),
  );

  test('bootstrap-ready gated provider sends exactly reviewed HTTP, not legacy',
      () async {
    final credentials = CloudCredentialStore(storage: _Secrets());
    await credentials.initialize();
    await credentials.setApiKey(
      'openAi', 'key-for-unit-test', accountId: 'account-one',
    );
    var reviews = 0;
    var httpRequests = 0;
    final client = MockClient((request) async {
      httpRequests++;
      expect(request.url.host, contains('openai'));
      expect(request.headers['authorization'], 'Bearer key-for-unit-test');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'gpt-test');
      expect(body['messages'], hasLength(3));
      expect((body['messages'] as List<dynamic>).last['content'],
          'Sensitive current question');
      return http.Response(jsonEncode(<String, Object?>{
        'model': 'gpt-test',
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, String>{'content': 'Approved completion'},
            'finish_reason': 'stop',
          }
        ],
        'usage': <String, int>{'total_tokens': 14},
      }), 200);
    });

    final bundle = HybridCloudAssistantRuntimeBundle.create(
      credentials: credentials,
      protectedStorage: _ConsentMemory(),
      client: client,
      supportedProviders: () => <String>['claude', 'gemini', 'openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'Cloud',
      modelForProvider: (_) => 'gpt-test',
      preferredProvider: () => 'openAi',
      automaticUseAllowed: (_) => true,
      chatReview: (session, review, isActive) async {
        reviews++;
        expect(session, 'real-chat-1');
        expect(isActive(), isTrue);
        expect(review.disclosure.accountId, 'account-one');
        expect(review.disclosure.credentialBindingId,
            credentials.consentBindingFor('openAi'));
        expect(review.disclosure.outboundText, contains('Earlier private text'));
        return <HybridDisclosureScope, HybridCloudConsentChoice>{
          for (final scope in review.needsConsent)
            scope: HybridCloudConsentChoice.allowOnce,
        };
      },
    );
    expect(bundle.provider.consentGated, isTrue);
    expect(bundle.provider.providerStatuses.map((status) => status.providerId),
        containsAllInOrder(<String>['gemini', 'openAi']));
    expect(bundle.provider.providerStatuses.map((status) => status.providerId),
        isNot(contains('claude')));

    final chunks = await bundle.provider.streamInference(
      request: authenticatedQuestion(),
      cancellationToken: CancellationToken(),
    ).toList();
    expect(chunks.last.isError, isFalse);
    expect(chunks.last.text, 'Approved completion');
    expect(reviews, 1);
    expect(httpRequests, 1);
    client.close();
  });

  test('missing trusted Chat evidence denies HTTP even with valid account',
      () async {
    final credentials = CloudCredentialStore(storage: _Secrets());
    await credentials.initialize();
    await credentials.setApiKey('openAi', 'key', accountId: 'account-one');
    var reviews = 0;
    var httpRequests = 0;
    final client = MockClient((_) async {
      httpRequests++;
      return http.Response('unexpected', 200);
    });
    final bundle = HybridCloudAssistantRuntimeBundle.create(
      credentials: credentials,
      protectedStorage: _ConsentMemory(),
      client: client,
      supportedProviders: () => <String>['openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'Cloud',
      modelForProvider: (_) => 'gpt-test',
      automaticUseAllowed: (_) => true,
      chatReview: (_, __, ___) async {
        reviews++;
        return <HybridDisclosureScope, HybridCloudConsentChoice>{};
      },
    );
    final chunks = await bundle.provider.streamInference(
      request: original,
      cancellationToken: CancellationToken(),
    ).toList();
    expect(chunks.last.isError, isTrue);
    expect(chunks.last.errorCode, InferenceErrorCode.cloudConsentDenied);
    expect(httpRequests, 0);
    expect(reviews, 0);
    client.close();
  });

  test('unsupported explicit pinned provider cannot silently become OpenAI',
      () async {
    final credentials = CloudCredentialStore(storage: _Secrets());
    await credentials.initialize();
    await credentials.setApiKey('openAi', 'key', accountId: 'account-one');
    var reviews = 0;
    var httpRequests = 0;
    final client = MockClient((_) async {
      httpRequests++;
      return http.Response('unexpected', 200);
    });
    final bundle = HybridCloudAssistantRuntimeBundle.create(
      credentials: credentials,
      protectedStorage: _ConsentMemory(),
      client: client,
      supportedProviders: () => <String>['openAi', 'claude'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'Cloud',
      modelForProvider: (_) => 'gpt-test',
      preferredProvider: () => 'openAi',
      automaticUseAllowed: (_) => true,
      chatReview: (_, __, ___) async {
        reviews++;
        return <HybridDisclosureScope, HybridCloudConsentChoice>{};
      },
    );
    final pinnedElsewhere = authenticatedQuestion().copyWith(
      cloudProviderId: 'claude',
      allowCloudProviderFailover: true,
    );
    final chunks = await bundle.provider.streamInference(
      request: pinnedElsewhere,
      cancellationToken: CancellationToken(),
    ).toList();
    expect(chunks.last.isError, isTrue);
    expect(httpRequests, 0);
    expect(reviews, 0);
    client.close();
  });

  test('environment-only Cloud keys are not eligible for gated dispatch',
      () async {
    final credentials = CloudCredentialStore(storage: _Secrets());
    await credentials.initialize(
      environmentFallbacks: <String, String>{'openAi': 'build-time-key'},
    );
    var httpRequests = 0;
    final client = MockClient((_) async {
      httpRequests++;
      return http.Response('unexpected', 200);
    });
    final bundle = HybridCloudAssistantRuntimeBundle.create(
      credentials: credentials,
      protectedStorage: _ConsentMemory(),
      client: client,
      supportedProviders: () => <String>['openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'Cloud',
      modelForProvider: (_) => 'gpt-test',
      automaticUseAllowed: (_) => true,
      chatReview: (_, __, ___) async => <HybridDisclosureScope,
          HybridCloudConsentChoice>{},
    );
    expect(bundle.provider.canInfer, isFalse);
    final result = await bundle.provider.streamInference(
      request: authenticatedQuestion(),
      cancellationToken: CancellationToken(),
    ).toList();
    expect(result.last.isError, isTrue);
    expect(httpRequests, 0);
    client.close();
  });
}
