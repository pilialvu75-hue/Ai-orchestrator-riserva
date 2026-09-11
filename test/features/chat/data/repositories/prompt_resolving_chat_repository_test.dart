import 'package:ai_orchestrator/core/config/ai/assistant_interaction_prompt_resolver.dart';
import 'package:ai_orchestrator/core/config/ai/assistant_system_prompt_service.dart';
import 'package:ai_orchestrator/core/config/ai/system_prompt_config.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/prompt_resolving_chat_repository.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<({AssistantSystemPromptService service, ConfigRepository config})>
      createService(Map<String, Object> initialValues) async {
    SharedPreferences.setMockInitialValues(initialValues);
    final preferences = await SharedPreferences.getInstance();
    final config = ConfigRepository(PreferencesService(preferences));
    return (
      service: AssistantSystemPromptService(configRepository: config),
      config: config,
    );
  }

  AssistantInteractionPromptResolver resolverFor(
    AssistantSystemPromptService service,
  ) =>
      AssistantInteractionPromptResolver(systemPromptService: service);

  group('AssistantSystemPromptService', () {
    test('uses conversational core when no preference exists', () async {
      final fixture = await createService(const <String, Object>{});

      expect(fixture.service.currentPrompt, SystemPromptConfig.defaultPrompt);
    });

    test('migrates only the historical bundled default', () async {
      final fixture = await createService(<String, Object>{
        AppConstants.prefDirectionalPrompt: SystemPromptConfig.legacyDefaultPrompt,
      });

      expect(await fixture.service.migrateLegacyDefaultIfNeeded(), isTrue);
      expect(
        fixture.config.getString(AppConstants.prefDirectionalPrompt),
        SystemPromptConfig.defaultPrompt,
      );
    });

    test('preserves a user-authored prompt', () async {
      const customPrompt = 'Be terse, technical, and answer in Italian.';
      final fixture = await createService(<String, Object>{
        AppConstants.prefDirectionalPrompt: customPrompt,
      });

      expect(await fixture.service.migrateLegacyDefaultIfNeeded(), isFalse);
      expect(fixture.service.currentPrompt, customPrompt);
    });
  });

  group('PromptResolvingChatRepository', () {
    test('replaces ordinary Assistant marker with stored custom prompt', () async {
      const customPrompt = 'Custom assistant identity.';
      final fixture = await createService(<String, Object>{
        AppConstants.prefDirectionalPrompt: customPrompt,
      });
      final delegate = _RecordingChatRepository();
      final repository = PromptResolvingChatRepository(
        delegate: delegate,
        promptResolver: resolverFor(fixture.service),
      );

      await repository.sendMessage(
        sessionId: 'assistant-session',
        userPrompt: 'continua',
        systemPrompt: SystemPromptConfig.defaultPrompt,
      );

      expect(delegate.lastSystemPrompt, customPrompt);
    });

    test('TEXT GENERAL leaves resolved prompt byte-for-byte unchanged', () async {
      const customPrompt = 'Custom assistant identity.\nKeep exact whitespace.';
      final fixture = await createService(<String, Object>{
        AppConstants.prefDirectionalPrompt: customPrompt,
      });
      final delegate = _RecordingChatRepository();
      final repository = PromptResolvingChatRepository(
        delegate: delegate,
        promptResolver: resolverFor(fixture.service),
      );

      await repository.sendMessage(
        sessionId: 'text-session',
        userPrompt: 'ciao',
        systemPrompt: SystemPromptConfig.defaultPrompt,
      );

      expect(delegate.lastSystemPrompt, customPrompt);
    });

    test('preserves explicit specialized system prompt', () async {
      final fixture = await createService(<String, Object>{
        AppConstants.prefDirectionalPrompt: 'Custom assistant identity.',
      });
      final delegate = _RecordingChatRepository();
      final repository = PromptResolvingChatRepository(
        delegate: delegate,
        promptResolver: resolverFor(fixture.service),
      );

      await repository.sendMessage(
        sessionId: 'special-session',
        userPrompt: 'run specialized task',
        systemPrompt: 'Specialized system prompt.',
      );

      expect(delegate.lastSystemPrompt, 'Specialized system prompt.');
    });

    test('delegates non-destructive active response cancellation', () async {
      final fixture = await createService(const <String, Object>{});
      final delegate = _RecordingChatRepository();
      final repository = PromptResolvingChatRepository(
        delegate: delegate,
        promptResolver: resolverFor(fixture.service),
      );

      await repository.cancelActiveResponse('default');

      expect(delegate.cancelledSessionId, 'default');
      expect(delegate.clearSessionCalls, 0);
    });
  });
}

class _RecordingChatRepository implements ChatRepository {
  String? lastSystemPrompt;
  String? cancelledSessionId;
  int clearSessionCalls = 0;

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async =>
      const <ChatMessage>[];

  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) async {
    lastSystemPrompt = systemPrompt;
    return ChatMessage(
      id: 'assistant-1',
      sessionId: sessionId,
      role: 'assistant',
      content: 'ok',
      timestamp: 1,
    );
  }

  @override
  Future<void> cancelActiveResponse(String sessionId) async {
    cancelledSessionId = sessionId;
  }

  @override
  Future<int> pruneHistory({
    int maxAgeDays = AppConstants.chatHistoryMaxAgeDays,
    int maxRows = AppConstants.chatHistoryMaxRows,
  }) async =>
      0;

  @override
  Future<void> clearSession(String sessionId) async {
    clearSessionCalls += 1;
  }

  @override
  Future<int> deleteMessagesFrom(String sessionId, String messageId) async => 0;
}
