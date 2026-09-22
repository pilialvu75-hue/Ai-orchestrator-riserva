import 'package:ai_orchestrator/core/config/ai/assistant_system_prompt_service.dart';
import 'package:ai_orchestrator/core/config/ai/system_prompt_config.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
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

  group('AssistantSystemPromptService', () {
    test('uses conversational core when no preference exists', () async {
      final fixture = await createService(const <String, Object>{});

      expect(fixture.service.currentPrompt, SystemPromptConfig.defaultPrompt);
    });

    test('migrates original historical bundled default', () async {
      final fixture = await createService(<String, Object>{
        AppConstants.prefDirectionalPrompt: SystemPromptConfig.legacyDefaultPrompt,
      });

      expect(await fixture.service.migrateLegacyDefaultIfNeeded(), isTrue);
      expect(
        fixture.config.getString(AppConstants.prefDirectionalPrompt),
        SystemPromptConfig.defaultPrompt,
      );
    });

    test('migrates conversational core v1 to compact v2', () async {
      final fixture = await createService(<String, Object>{
        AppConstants.prefDirectionalPrompt:
            SystemPromptConfig.previousDefaultPromptV1,
      });

      expect(fixture.service.currentPrompt, SystemPromptConfig.defaultPrompt);
      expect(await fixture.service.migrateLegacyDefaultIfNeeded(), isTrue);
      expect(
        fixture.config.getString(AppConstants.prefDirectionalPrompt),
        SystemPromptConfig.defaultPrompt,
      );
    });

    test('classifies ordinary and specialized Assistant prompts', () async {
      final fixture = await createService(const <String, Object>{});

      expect(fixture.service.isOrdinaryAssistantRequest(null), isTrue);
      expect(
        fixture.service.isOrdinaryAssistantRequest(SystemPromptConfig.defaultPrompt),
        isTrue,
      );
      expect(
        fixture.service.isOrdinaryAssistantRequest('Specialized system prompt.'),
        isFalse,
      );
    });

    test('preserves a user-authored prompt', () async {
      const customPrompt = 'Be terse, technical, and answer in Italian.';
      final fixture = await createService(<String, Object>{
        AppConstants.prefDirectionalPrompt: customPrompt,
      });

      expect(await fixture.service.migrateLegacyDefaultIfNeeded(), isFalse);
      expect(fixture.service.currentPrompt, customPrompt);
      expect(
        fixture.config.getString(AppConstants.prefDirectionalPrompt),
        customPrompt,
      );
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
        systemPromptService: fixture.service,
        durableMemoryContextService: _emptyMemoryContext(),
      );

      await repository.sendMessage(
        sessionId: 'assistant-session',
        userPrompt: 'continua',
        systemPrompt: SystemPromptConfig.defaultPrompt,
      );

      expect(delegate.lastSystemPrompt, customPrompt);
    });

    test('upgrades incoming v1 stock marker to current configured identity',
        () async {
      final fixture = await createService(<String, Object>{
        AppConstants.prefDirectionalPrompt:
            SystemPromptConfig.previousDefaultPromptV1,
      });
      final delegate = _RecordingChatRepository();
      final repository = PromptResolvingChatRepository(
        delegate: delegate,
        systemPromptService: fixture.service,
        durableMemoryContextService: _emptyMemoryContext(),
      );

      await repository.sendMessage(
        sessionId: 'assistant-session',
        userPrompt: 'continua',
        systemPrompt: SystemPromptConfig.previousDefaultPromptV1,
      );

      expect(delegate.lastSystemPrompt, SystemPromptConfig.defaultPrompt);
    });

    test('ordinary Assistant chat receives relevant confirmed durable memory',
        () async {
      final fixture = await createService(const <String, Object>{});
      final persistence = _PromptMemoryPersistence();
      final memoryService = AssistantDurableMemoryService(
        store: AssistantDurableMemoryStore(persistence: persistence),
      );
      await memoryService.recordConfirmed(
        recordKey: 'bike.current',
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        kind: AssistantMemoryKind.state,
        content: 'La bici attuale è quella nuova.',
        source: AssistantMemorySource.userExplicit,
        updatedAt: 10,
      );
      final delegate = _RecordingChatRepository();
      final repository = PromptResolvingChatRepository(
        delegate: delegate,
        systemPromptService: fixture.service,
        durableMemoryContextService: AssistantDurableMemoryContextService(
          memoryService: memoryService,
        ),
      );

      await repository.sendMessage(
        sessionId: 'assistant-session',
        userPrompt: 'Qual è la mia bici attuale?',
        systemPrompt: SystemPromptConfig.defaultPrompt,
      );

      expect(delegate.lastSystemPrompt, contains(SystemPromptConfig.defaultPrompt));
      expect(delegate.lastSystemPrompt, contains('CONFIRMED DURABLE MEMORY'));
      expect(delegate.lastSystemPrompt, contains('La bici attuale è quella nuova.'));
    });

    test('preserves explicit specialized system prompt', () async {
      final fixture = await createService(<String, Object>{
        AppConstants.prefDirectionalPrompt: 'Custom assistant identity.',
      });
      final delegate = _RecordingChatRepository();
      final repository = PromptResolvingChatRepository(
        delegate: delegate,
        systemPromptService: fixture.service,
        durableMemoryContextService: _emptyMemoryContext(),
      );

      await repository.sendMessage(
        sessionId: 'special-session',
        userPrompt: 'run specialized task',
        systemPrompt: 'Specialized system prompt.',
      );

      expect(delegate.lastSystemPrompt, 'Specialized system prompt.');
      expect(delegate.lastSystemPrompt, isNot(contains('DURABLE MEMORY')));
    });
  });
}

class _RecordingChatRepository implements ChatRepository {
  String? lastSystemPrompt;

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
  Future<int> pruneHistory({
    int maxAgeDays = AppConstants.chatHistoryMaxAgeDays,
    int maxRows = AppConstants.chatHistoryMaxRows,
  }) async =>
      0;

  @override
  Future<void> clearSession(String sessionId) async {}

  @override
  Future<int> deleteMessagesFrom(String sessionId, String messageId) async => 0;
}

AssistantDurableMemoryContextService _emptyMemoryContext() {
  return AssistantDurableMemoryContextService(
    memoryService: AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(
        persistence: _PromptMemoryPersistence(),
      ),
    ),
  );
}

class _PromptMemoryPersistence implements AssistantDurableMemoryPersistence {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
