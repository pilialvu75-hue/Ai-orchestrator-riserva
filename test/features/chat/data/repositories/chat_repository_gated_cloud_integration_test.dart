import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_assistant_runtime_bundle.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/models/chat_message_model.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:ai_orchestrator/features/chat_memory/conversation_memory_service.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';

final class _ChatStore implements ChatLocalDataSource {
  final rows = <ChatMessageModel>[];
  @override
  Future<void> insertMessage(ChatMessageModel message) async => rows.add(message);
  @override
  Future<List<ChatMessageModel>> getMessages(String id) async =>
      rows.where((row) => row.sessionId == id).toList();
  @override
  Future<int> clearSession(String id) async => 0;
  @override
  Future<int> countMessages() async => rows.length;
  @override
  Future<int> deleteOldMessages(DateTime cutoff) async => 0;
  @override
  Future<int> deleteExcessMessages(int max) async => 0;
  @override
  Future<int> deleteMessagesFrom(String sessionId, String messageId) async => 0;
}

final class _Memory extends Mock implements ConversationMemoryService {}
final class _Mode extends Mock implements AiRuntimeSettingsService {}
final class _Runtime extends Mock implements InferenceService {}

final class _ProtectedStorage implements HybridCloudConsentStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
  @override
  Future<void> delete(String key) async { values.remove(key); }
}

final class _SecretStorage implements CloudSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
  @override
  Future<void> delete(String key) async { values.remove(key); }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const InferenceRequest(
      sessionId: 'fallback', prompt: 'fallback',
    ));
  });

  Future<void> runChat({required bool allow}) async {
    const session = 'gated-chat-1';
    const question = 'Explain the architecture';
    const system = 'Base assistant instructions.';
    final database = _ChatStore();
    final memory = _Memory();
    final settings = _Mode();
    final inference = _Runtime();
    when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.cloud);
    when(() => settings.manualCloudProvider).thenReturn('openAi');
    when(() => memory.buildContext(
      sessionId: any(named: 'sessionId'),
      messages: any(named: 'messages'),
      userPrompt: any(named: 'userPrompt'),
      systemPrompt: any(named: 'systemPrompt'),
      excludedMessageId: any(named: 'excludedMessageId'),
    )).thenAnswer((_) async => <ChatTurn>[]);
    when(() => memory.storeMessageEmbedding(
      sessionId: any(named: 'sessionId'),
      messageId: any(named: 'messageId'),
      role: any(named: 'role'),
      content: any(named: 'content'),
      timestamp: any(named: 'timestamp'),
    )).thenAnswer((_) async {});

    final secrets = CloudCredentialStore(storage: _SecretStorage());
    await secrets.initialize();
    await secrets.setApiKey('openAi', 'synthetic-secret',
        accountId: 'synthetic-account');
    var reviews = 0;
    var networkPosts = 0;
    final httpClient = MockClient((request) async {
      networkPosts++;
      expect(request.url.host, contains('openai'));
      expect(request.headers['authorization'], 'Bearer synthetic-secret');
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload['model'], 'gpt-synthetic');
      expect(jsonEncode(payload['messages']), contains(question));
      expect(jsonEncode(payload['messages']), contains(system));
      return http.Response(jsonEncode(<String, Object?>{
        'model': 'gpt-synthetic',
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, String>{'content': 'Approved response'},
            'finish_reason': 'stop',
          },
        ],
        'usage': <String, int>{'total_tokens': 10},
      }), 200);
    });
    final gated = HybridCloudAssistantRuntimeBundle.create(
      credentials: secrets,
      protectedStorage: _ProtectedStorage(),
      client: httpClient,
      supportedProviders: () => <String>['openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'Cloud',
      modelForProvider: (_) => 'gpt-synthetic',
      preferredProvider: () => 'openAi',
      automaticUseAllowed: (_) => true,
      chatReview: (chatSessionId, review, isActive) async {
        reviews++;
        expect(chatSessionId, session);
        expect(isActive(), isTrue);
        expect(review.disclosure.outboundText, contains(question));
        expect(review.disclosure.accountId, 'synthetic-account');
        if (!allow) return <HybridDisclosureScope, HybridCloudConsentChoice>{};
        return <HybridDisclosureScope, HybridCloudConsentChoice>{
          for (final scope in review.needsConsent)
            scope: HybridCloudConsentChoice.allowOnce,
        };
      },
    );
    when(() => inference.stream(any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments.single as InferenceRequest;
      expect(request.routeDirective, InferenceRouteDirective.cloudOnly);
      expect(request.cloudProviderId, 'openAi');
      expect(request.trustedCloudSourceEvidence, isNotNull);
      expect(request.trustedCloudSourceEvidence!.sessionId, session);
      expect(request.trustedCloudSourceEvidence!.originalQuestion, question);
      return gated.provider.streamInference(
        request: request,
        cancellationToken: CancellationToken(),
      );
    });
    final chat = ChatRepositoryImpl(
      localDataSource: database,
      conversationMemoryService: memory,
      inferenceService: inference,
      runtimeSettingsService: settings,
      consentGatedAssistantCloud: true,
    );

    if (allow) {
      final answer = await chat.sendMessage(
        sessionId: session, userPrompt: question, systemPrompt: system,
      );
      expect(answer.content, 'Approved response');
      expect(answer.provider, 'openAi');
      expect(database.rows.map((message) => message.role),
          <String>['user', 'assistant']);
      expect(database.rows.last.content, 'Approved response');
      expect(networkPosts, 1);
    } else {
      await expectLater(
        chat.sendMessage(
          sessionId: session, userPrompt: question, systemPrompt: system,
        ),
        throwsA(isA<ServerFailure>()),
      );
      expect(database.rows.map((message) => message.role), <String>['user']);
      expect(networkPosts, 0);
    }
    expect(reviews, 1);
    httpClient.close();
  }

  test('real Chat origin -> gated review -> single approved HTTP -> reply',
      () async {
    await runChat(allow: true);
  });

  test('real Chat origin -> refusal -> no HTTP and no assistant fabrication',
      () async {
    await runChat(allow: false);
  });
}
