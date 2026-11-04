import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_ai_request_seal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_native_wire_sender.dart';
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

final class _SecretMemory implements CloudSecretStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async { data[key] = value; }
  @override
  Future<void> delete(String key) async { data.remove(key); }
}

void main() {
  const controls = HybridDisclosureScope(
    HybridDisclosureOrigin.systemInstructions,
    HybridDisclosureSensitivity.publicOrNonPersonal,
  );
  const system = HybridDisclosureScope(
    HybridDisclosureOrigin.systemInstructions,
    HybridDisclosureSensitivity.confidential,
  );
  const question = HybridDisclosureScope(
    HybridDisclosureOrigin.currentQuestion,
    HybridDisclosureSensitivity.personal,
  );
  const rag = HybridDisclosureScope(
    HybridDisclosureOrigin.documentExcerpt,
    HybridDisclosureSensitivity.confidential,
  );
  const history = HybridDisclosureScope(
    HybridDisclosureOrigin.conversationHistory,
    HybridDisclosureSensitivity.personal,
  );

  late CloudCredentialStore credentials;
  late HybridCloudDisclosureConsent consent;
  var sends = 0;

  setUp(() async {
    credentials = CloudCredentialStore(storage: _SecretMemory());
    await credentials.initialize();
    consent = HybridCloudDisclosureConsent(
      backend: _ConsentMemory(),
      authorizeOwnerSession: (ownerId, sessionId) async =>
          ownerId == 'owner-a' && sessionId == 'chat-a',
    );
    sends = 0;
  });

  HybridCloudAiRequestSeal sealed(String providerId,
      {String accountId = 'account-a'}) {
    final request = AiRequest(
      prompt: 'Read this: PRIVATE PDF',
      systemPrompt: 'Be precise',
      messages: const <AiMessage>[
        AiMessage(role: AiMessageRole.user, content: 'Private older message'),
        AiMessage(role: AiMessageRole.assistant, content: 'Older answer'),
      ],
      modelId: providerId == 'openAi' ? 'gpt-test' : 'gemini-test',
      providerId: providerId,
      temperature: 0.3,
      maxTokens: 1024,
      taskType: 'general',
    );
    return HybridCloudAiRequestSeal.fromRequest(
      ownerId: 'owner-a',
      sessionId: 'chat-a',
      accountId: accountId,
      purpose: 'Respond to a user request with selected context',
      request: request,
      controlScope: controls,
      systemPromptSegments: const <HybridDisclosureSegment>[
        HybridDisclosureSegment(text: 'Be precise', scope: system),
      ],
      historyScopes: const <HybridDisclosureScope>[history, history],
      promptSegments: const <HybridDisclosureSegment>[
        HybridDisclosureSegment(text: 'Read this: ', scope: question),
        HybridDisclosureSegment(text: 'PRIVATE PDF', scope: rag),
      ],
    );
  }

  Future<HybridCloudDispatchPermit> approve(
      HybridCloudAiRequestSeal seal) async =>
      (await consent.authorizeForDispatch(
        disclosure: seal.disclosure,
        requestConsent: (review) async =>
            <HybridDisclosureScope, HybridCloudConsentChoice>{
          for (final scope in review.needsConsent)
            scope: HybridCloudConsentChoice.allowOnce,
        },
      ))!;

  HybridCloudNativeWireSender sender(MockClient client) =>
      HybridCloudNativeWireSender(
        consent: consent,
        credentials: credentials,
        client: client,
      );

  test('OpenAI sends only reviewed system/history/prompt with actual JSON',
      () async {
    await credentials.setApiKey('openAi', 'fake-key', accountId: 'account-a');
    final item = sealed('openAi');
    final permit = await approve(item);
    final native = sender(MockClient((request) async {
      sends++;
      expect(request.url.path, endsWith('/chat/completions'));
      expect(request.headers['authorization'], 'Bearer fake-key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'gpt-test');
      final messages = body['messages'] as List<dynamic>;
      expect(messages, hasLength(4));
      expect(messages.first['role'], 'system');
      expect(messages.first['content'], 'Be precise');
      expect(messages[1]['content'], 'Private older message');
      expect(messages.last['content'], 'Read this: PRIVATE PDF');
      expect(request.body, isNot(contains('account-a')));
      return http.Response('{"ok":true}', 200);
    }));
    expect((await native.send(seal: item, permit: permit, expectedCredentialSecret: 'fake-key')).statusCode, 200);
    expect(sends, 1);
    await expectLater(native.send(seal: item, permit: permit, expectedCredentialSecret: 'fake-key'),
        throwsStateError);
    expect(sends, 1);
  });

  test('Gemini uses actual generateContent serializer and pinned account',
      () async {
    await credentials.setApiKey('gemini', 'fake-key', accountId: 'account-a');
    final item = sealed('gemini');
    final native = sender(MockClient((request) async {
      sends++;
      expect(request.url.path, contains('gemini-test:generateContent'));
      expect(request.headers['x-goog-api-key'], 'fake-key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['systemInstruction']['parts'][0]['text'], 'Be precise');
      expect(body['contents'], hasLength(3));
      expect(body['contents'][0]['parts'][0]['text'], 'Private older message');
      expect(body['contents'][2]['parts'][0]['text'], 'Read this: PRIVATE PDF');
      expect(body['generationConfig']['maxOutputTokens'], 1024);
      return http.Response('{"ok":true}', 200);
    }));
    expect((await native.send(
        seal: item, permit: await approve(item),
        expectedCredentialSecret: 'fake-key')).statusCode, 200);
    expect(sends, 1);
  });

  test('credential account switched after review blocks HTTP', () async {
    await credentials.setApiKey('gemini', 'key1', accountId: 'account-a');
    final item = sealed('gemini');
    final permit = await approve(item);
    await credentials.setApiKey('gemini', 'key2', accountId: 'account-b');
    await expectLater(sender(MockClient((request) async {
      sends++;
      return http.Response('bad', 200);
    })).send(seal: item, permit: permit,
        expectedCredentialSecret: 'key1'), throwsStateError);
    expect(sends, 0);
  });

  test('rotated API key for SAME labeled account cannot use approved HTTP',
      () async {
    await credentials.setApiKey('gemini', 'old-secret', accountId: 'account-a');
    final item = sealed('gemini');
    final permit = await approve(item);
    // A different token can be entered for the same human-readable account
    // label while the review is open. An account name alone is not proof.
    await credentials.setApiKey('gemini', 'new-secret', accountId: 'account-a');
    await expectLater(sender(MockClient((request) async {
      sends++;
      return http.Response('unexpected-send', 200);
    })).send(seal: item, permit: permit,
        expectedCredentialSecret: 'old-secret'), throwsStateError);
    expect(sends, 0);
  });

  test('missing account binding blocks HTTP, even with an approved receipt',
      () async {
    await credentials.setApiKey('openAi', 'key-no-account');
    final item = sealed('openAi');
    await expectLater(sender(MockClient((request) async {
      sends++;
      return http.Response('bad', 200);
    })).send(seal: item, permit: await approve(item),
        expectedCredentialSecret: 'key-no-account'), throwsStateError);
    expect(sends, 0);
  });

  test('unsupported provider cannot silently fall back to another provider',
      () async {
    await credentials.setApiKey('openAi', 'key', accountId: 'account-a');
    final item = sealed('claude');
    await expectLater(sender(MockClient((request) async {
      sends++;
      return http.Response('bad', 200);
    })).send(seal: item, permit: await approve(item),
        expectedCredentialSecret: 'key'), throwsStateError);
    expect(sends, 0);
  });

  test('different sealed account cannot reuse the prior disclosure permit',
      () async {
    await credentials.setApiKey('gemini', 'key', accountId: 'account-a');
    final original = sealed('gemini');
    final other = sealed('gemini', accountId: 'account-b');
    final permit = await approve(original);
    await expectLater(sender(MockClient((request) async {
      sends++;
      return http.Response('bad', 200);
    })).send(seal: other, permit: permit,
        expectedCredentialSecret: 'key'), throwsStateError);
    expect(sends, 0);
  });
}
