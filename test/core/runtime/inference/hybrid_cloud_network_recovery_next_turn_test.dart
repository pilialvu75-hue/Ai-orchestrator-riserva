import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_assistant_runtime_bundle.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_runtime_source_evidence.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final class _TestProtectedStorage
    implements CloudSecretStorage, HybridCloudConsentStorage {
  final Map<String, String> _entries = <String, String>{};

  @override
  Future<String?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, String value) async {
    _entries[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _entries.remove(key);
  }
}

InferenceRequest _trustedNewTurn(String session, String question) =>
    InferenceRequest(
      sessionId: session,
      prompt: question,
      systemPrompt: 'No private memory may leave without review.',
      routeDirective: InferenceRouteDirective.cloudOnly,
      cloudProviderId: 'openAi',
      allowCloudProviderFailover: false,
      trustedCloudSourceEvidence: HybridCloudRuntimeSourceEvidence(
        sessionId: session,
        originalQuestion: question,
        baseSystemPrompt: 'No private memory may leave without review.',
        originalHistory: const <AiMessage>[],
      ),
    );

void main() {
  test('H47 offline HYBRID holds LOCAL, then a NEW authorized turn '
      'returns to the same Cloud provider after cooldown', () async {
    final secrets = _TestProtectedStorage();
    final credentials = CloudCredentialStore(storage: secrets);
    await credentials.initialize();
    await credentials.setApiKey('openAi', 'synthetic-key-DO-NOT-SEND',
        accountId: 'test-account');

    var clock = DateTime.utc(2026, 11, 6, 12);
    var postCount = 0;
    var reviewCount = 0;
    final reviewedSessions = <String>[];
    final client = MockClient((request) async {
      postCount++;
      expect(request.url.host, contains('openai'));
      expect(request.headers['authorization'],
          'Bearer synthetic-key-DO-NOT-SEND');
      if (postCount == 1) {
        throw http.ClientException(
            'SYNTHETIC transport drop; should never disclose raw body');
      }
      expect(postCount, 2);
      expect(request.body, contains('Second new question'));
      expect(request.body, isNot(contains('LOCAL PRIVATE MEMORY')));
      return http.Response(jsonEncode(<String, Object?>{
        'model': 'gpt-test',
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, String>{'content': 'Cloud restored'},
            'finish_reason': 'stop',
          }
        ],
        'usage': <String, int>{'total_tokens': 8},
      }), 200);
    });
    final bundle = HybridCloudAssistantRuntimeBundle.create(
      credentials: credentials,
      protectedStorage: _TestProtectedStorage(),
      client: client,
      supportedProviders: () => <String>['gemini', 'openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'Cloud',
      modelForProvider: (_) => 'gpt-test',
      preferredProvider: () => 'openAi',
      automaticUseAllowed: (_) => true,
      now: () => clock,
      chatReview: (session, review, isActive) async {
        reviewCount++;
        reviewedSessions.add(session);
        expect(isActive(), isTrue);
        expect(review.disclosure.providerId, 'openAi');
        expect(review.disclosure.accountId, 'test-account');
        return <HybridDisclosureScope, HybridCloudConsentChoice>{
          for (final scope in review.needsConsent)
            scope: HybridCloudConsentChoice.allowOnce,
        };
      },
    );
    final first = _trustedNewTurn('old-chat', 'First original question');
    final firstOutput = await bundle.provider.streamInference(
      request: first,
      cancellationToken: CancellationToken(),
    ).toList();
    expect(firstOutput.last.isError, isTrue);
    expect(firstOutput.last.errorCode,
        InferenceErrorCode.cloudTransportUnavailable);
    expect(firstOutput.last.errorMessage, isNot(contains('SYNTHETIC')));
    expect(bundle.provider.providerStatuses
        .singleWhere((s) => s.providerId == 'openAi').state,
        CloudProviderOperationalState.temporarilyUnavailable);
    expect(bundle.provider.recommendProviderFor(first,
        enforceAutomaticPolicy: true), isNull);
    expect(postCount, 1);
    expect(reviewCount, 1);

    // Neither the 20-second cooldown nor moving the clock causes a replay.
    clock = clock.add(const Duration(seconds: 19));
    expect(bundle.provider.recommendProviderFor(first,
        enforceAutomaticPolicy: true), isNull);
    expect(postCount, 1);
    clock = clock.add(const Duration(seconds: 2));
    final second = _trustedNewTurn('fresh-chat', 'Second new question');
    expect(bundle.provider.recommendProviderFor(second,
        enforceAutomaticPolicy: true), 'openAi');
    expect(postCount, 1); // No automatic resend after network recovery.

    final secondOutput = await bundle.provider.streamInference(
      request: second,
      cancellationToken: CancellationToken(),
    ).toList();
    expect(secondOutput.last.text, 'Cloud restored');
    expect(secondOutput.last.isError, isFalse);
    expect(secondOutput.last.providerId, 'openAi');
    expect(postCount, 2);
    // allowOnce MUST be reviewed again, even if the network recovered.
    expect(reviewCount, 2);
    expect(reviewedSessions, <String>['old-chat', 'fresh-chat']);
    expect(bundle.provider.providerStatuses
        .singleWhere((s) => s.providerId == 'openAi').state,
        CloudProviderOperationalState.ready);
    client.close();
  });
}
