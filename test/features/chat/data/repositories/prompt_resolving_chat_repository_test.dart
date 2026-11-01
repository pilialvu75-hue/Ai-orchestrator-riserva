import 'package:ai_orchestrator/core/config/ai/assistant_system_prompt_service.dart';
import 'package:ai_orchestrator/core/config/ai/system_prompt_config.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
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

    test('explicit memory is updated, recalled across chats and forgotten',
        () async {
      final fixture = await createService(const <String, Object>{});
      final persistence = _PromptMemoryPersistence();
      final memory = AssistantDurableMemoryService(
        store: AssistantDurableMemoryStore(persistence: persistence),
      );
      final delegate = _RecordingChatRepository();
      final repository = PromptResolvingChatRepository(
        delegate: delegate,
        systemPromptService: fixture.service,
        durableMemoryContextService: AssistantDurableMemoryContextService(
          memoryService: memory,
        ),
        durableMemoryCaptureService: AssistantDurableMemoryCaptureService(
          memoryService: memory,
          now: () => 42,
        ),
      );

      await repository.sendMessage(
        sessionId: 'session-one',
        userPrompt: 'Ricorda che il budget è 420',
      );
      await repository.sendMessage(
        sessionId: 'session-two',
        userPrompt: 'Qual è il budget?',
      );
      expect(delegate.lastSystemPrompt, contains('il budget è 420'));

      await repository.sendMessage(
        sessionId: 'session-two',
        userPrompt: 'Ricorda che il budget è 680',
      );
      await repository.sendMessage(
        sessionId: 'session-three',
        userPrompt: 'Qual è il budget?',
      );
      expect(delegate.lastSystemPrompt, contains('il budget è 680'));
      expect(delegate.lastSystemPrompt, isNot(contains('il budget è 420')));

      await repository.sendMessage(
        sessionId: 'session-three',
        userPrompt: 'Dimentica il budget',
      );
      await repository.sendMessage(
        sessionId: 'session-four',
        userPrompt: 'Qual è il budget?',
      );
      expect(delegate.lastSystemPrompt, isNot(contains('CONFIRMED DURABLE MEMORY')));
    });

    test('Qwen to Phi handoff keeps confirmed user facts across sessions',
        () async {
      final fixture = await createService(const <String, Object>{});
      // The same local durable store belongs to Aivexus, never to an LLM.
      final disk = _PromptMemoryPersistence();
      final writerMemory = AssistantDurableMemoryService(
        store: AssistantDurableMemoryStore(persistence: disk),
      );
      final qwenRuntime = _RecordingChatRepository();
      final qwen = PromptResolvingChatRepository(
        delegate: qwenRuntime,
        systemPromptService: fixture.service,
        durableMemoryContextService: AssistantDurableMemoryContextService(
          memoryService: writerMemory,
        ),
        durableMemoryCaptureService: AssistantDurableMemoryCaptureService(
          memoryService: writerMemory,
          now: () => 101,
        ),
      );

      await qwen.sendMessage(
        sessionId: 'qwen-session',
        userPrompt: 'Ricorda che il numero di prova è 731',
      );
      expect(qwenRuntime.lastSystemPrompt, contains('numero di prova è 731'));

      // A new repository, memory service and chat session simulate a model
      // switch or an app restart. Only storage is shared, not model state.
      final phiMemory = AssistantDurableMemoryService(
        store: AssistantDurableMemoryStore(persistence: disk),
      );
      final phiRuntime = _RecordingChatRepository();
      final phi = PromptResolvingChatRepository(
        delegate: phiRuntime,
        systemPromptService: fixture.service,
        durableMemoryContextService: AssistantDurableMemoryContextService(
          memoryService: phiMemory,
        ),
        durableMemoryCaptureService: AssistantDurableMemoryCaptureService(
          memoryService: phiMemory,
          now: () => 102,
        ),
      );
      await phi.sendMessage(
        sessionId: 'phi-session',
        userPrompt: 'Quanto vale il numero di prova?',
      );
      expect(phiRuntime.lastSystemPrompt, contains('numero di prova è 731'));
      expect(phiRuntime.lastSystemPrompt, contains('origin=userExplicit'));

      // An unverified model suggestion must not leak into another model's
      // confirmed memory, even though it is in the very same SQLite scope.
      await phiMemory.recordModelCandidate(
        recordKey: 'numero.di.prova.suggerito',
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        kind: AssistantMemoryKind.fact,
        content: 'numero di prova è 999',
        updatedAt: 103,
      );
      await phi.sendMessage(
        sessionId: 'phi-session',
        userPrompt: 'Quanto vale il numero di prova?',
      );
      expect(phiRuntime.lastSystemPrompt, contains('numero di prova è 731'));
      expect(phiRuntime.lastSystemPrompt,
          isNot(contains('numero di prova è 999')));

      // A confirmed correction written while Phi is selected immediately
      // becomes available to the next model, without retraining or replay.
      await phi.sendMessage(
        sessionId: 'phi-session',
        userPrompt: 'Ricorda che il numero di prova è 732',
      );
      await qwen.sendMessage(
        sessionId: 'qwen-new-session',
        userPrompt: 'Quanto vale il numero di prova?',
      );
      expect(qwenRuntime.lastSystemPrompt, contains('numero di prova è 732'));
      expect(qwenRuntime.lastSystemPrompt,
          isNot(contains('numero di prova è 731')));

      // Forgetting is global to this user's approved memory, irrespective
      // of the model that recorded or consumed it.
      await qwen.sendMessage(
        sessionId: 'qwen-new-session',
        userPrompt: 'Dimentica il numero di prova',
      );
      await phi.sendMessage(
        sessionId: 'phi-new-session',
        userPrompt: 'Quanto vale il numero di prova?',
      );
      expect(phiRuntime.lastSystemPrompt,
          isNot(contains('numero di prova è 732')));
      expect(phiRuntime.lastSystemPrompt,
          isNot(contains('CONFIRMED DURABLE MEMORY')));
    });

    test('tested procedure survives model replacement but model guess does not',
        () async {
      final fixture = await createService(const <String, Object>{});
      final disk = _PromptMemoryPersistence();
      final qwenKnowledge = AssistantDurableMemoryService(
        store: AssistantDurableMemoryStore(persistence: disk),
      );

      // A validated result, not a free-form model answer, can be promoted
      // into the shared knowledge store under a stable Aivexus identity.
      await qwenKnowledge.recordConfirmed(
        recordKey: 'procedure.diagnostics.android',
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        kind: AssistantMemoryKind.procedure,
        content: 'Procedura verificata diagnostica Android: leggere i log '
            'locali prima di proporre cambiamenti.',
        source: AssistantMemorySource.verifiedTest,
        updatedAt: 42,
      );
      await qwenKnowledge.recordModelCandidate(
        recordKey: 'procedure.diagnostics.guess',
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        kind: AssistantMemoryKind.procedure,
        content: 'Procedura non verificata diagnostica Android: '
            'cancellare tutti i dati.',
        updatedAt: 43,
      );

      final phiRuntime = _RecordingChatRepository();
      final phi = PromptResolvingChatRepository(
        delegate: phiRuntime,
        systemPromptService: fixture.service,
        durableMemoryContextService: AssistantDurableMemoryContextService(
          memoryService: AssistantDurableMemoryService(
            store: AssistantDurableMemoryStore(persistence: disk),
          ),
        ),
      );
      await phi.sendMessage(
        sessionId: 'new-model-phi',
        userPrompt: 'Quale procedura diagnostica Android abbiamo verificato?',
      );
      expect(phiRuntime.lastSystemPrompt, contains('origin=verifiedTest'));
      expect(phiRuntime.lastSystemPrompt,
          contains('Procedura verificata diagnostica Android'));
      expect(phiRuntime.lastSystemPrompt,
          isNot(contains('cancellare tutti i dati')));

      // A suggestion cannot be labeled as a reusable verified skill by a
      // model without the independent test evidence.
      expect(
        () => qwenKnowledge.recordConfirmed(
          recordKey: 'procedure.diagnostics.guess',
          scope: AssistantMemoryScope.user,
          scopeId: AssistantDurableMemoryContextService.localUserScopeId,
          kind: AssistantMemoryKind.procedure,
          content: 'Procedura non testata',
          source: AssistantMemorySource.modelCandidate,
          updatedAt: 44,
        ),
        throwsArgumentError,
      );
      await expectLater(
        qwenKnowledge.recordConfirmed(
          recordKey: 'procedure.diagnostics.unchecked',
          scope: AssistantMemoryScope.user,
          scopeId: AssistantDurableMemoryContextService.localUserScopeId,
          kind: AssistantMemoryKind.procedure,
          content: 'Istruzione non verificata',
          source: AssistantMemorySource.userExplicit,
          updatedAt: 45,
        ),
        throwsArgumentError,
      );
    });

    test('conversation-only facts never become global at model handoff',
        () async {
      final fixture = await createService(const <String, Object>{});
      final disk = _PromptMemoryPersistence();
      final memory = AssistantDurableMemoryService(
        store: AssistantDurableMemoryStore(persistence: disk),
      );
      final capture = AssistantDurableMemoryCaptureService(
        memoryService: memory,
        now: () => 501,
      );
      final qwen = PromptResolvingChatRepository(
        delegate: _RecordingChatRepository(),
        systemPromptService: fixture.service,
        durableMemoryContextService: AssistantDurableMemoryContextService(
          memoryService: memory,
        ),
        durableMemoryCaptureService: capture,
      );
      final phiRuntime = _RecordingChatRepository();
      final phi = PromptResolvingChatRepository(
        delegate: phiRuntime,
        systemPromptService: fixture.service,
        durableMemoryContextService: AssistantDurableMemoryContextService(
          memoryService: AssistantDurableMemoryService(
            store: AssistantDurableMemoryStore(persistence: disk),
          ),
        ),
      );
      await qwen.sendMessage(
        sessionId: 'private-chat',
        userPrompt: 'Ricorda solo in questa chat che il budget è 420',
      );
      await phi.sendMessage(
        sessionId: 'other-chat',
        userPrompt: 'Qual è il budget?',
      );
      expect(phiRuntime.lastSystemPrompt,
          isNot(contains('il budget è 420')));
      await phi.sendMessage(
        sessionId: 'private-chat',
        userPrompt: 'Qual è il budget?',
      );
      expect(phiRuntime.lastSystemPrompt, contains('il budget è 420'));
    });

    test('specialized Assistant requests cannot create durable user facts',
        () async {
      final fixture = await createService(const <String, Object>{});
      final persistence = _PromptMemoryPersistence();
      final memory = AssistantDurableMemoryService(
        store: AssistantDurableMemoryStore(persistence: persistence),
      );
      final repository = PromptResolvingChatRepository(
        delegate: _RecordingChatRepository(),
        systemPromptService: fixture.service,
        durableMemoryContextService: AssistantDurableMemoryContextService(
          memoryService: memory,
        ),
        durableMemoryCaptureService: AssistantDurableMemoryCaptureService(
          memoryService: memory,
        ),
      );

      await repository.sendMessage(
        sessionId: 'worker',
        userPrompt: 'Ricorda che il budget è 999',
        systemPrompt: 'Specialized system prompt.',
      );
      expect(
        await memory.loadConfirmed(
          scope: AssistantMemoryScope.user,
          scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        ),
        isEmpty,
      );
    });

    test('ordinary Assistant follows a French to Italian turn switch',
        () async {
      final fixture = await createService(const <String, Object>{});
      final delegate = _RecordingChatRepository();
      final repository = PromptResolvingChatRepository(
        delegate: delegate,
        systemPromptService: fixture.service,
        durableMemoryContextService: _emptyMemoryContext(),
      );

      await repository.sendMessage(
        sessionId: 'same-conversation',
        userPrompt: "comment s'appelle mon pote?",
      );
      expect(delegate.lastSystemPrompt, contains('write in French'));

      await repository.sendMessage(
        sessionId: 'same-conversation',
        userPrompt: 'come mi chiamo?',
      );
      expect(delegate.lastSystemPrompt, contains('write in Italian'));
      expect(delegate.lastSystemPrompt, isNot(contains('write in French')));
    });

    test('custom fixed-language prompt remains authoritative', () async {
      const fixedItalian = 'Always answer in Italian.';
      final fixture = await createService(<String, Object>{
        AppConstants.prefDirectionalPrompt: fixedItalian,
      });
      final delegate = _RecordingChatRepository();
      final repository = PromptResolvingChatRepository(
        delegate: delegate,
        systemPromptService: fixture.service,
        durableMemoryContextService: _emptyMemoryContext(),
      );

      await repository.sendMessage(
        sessionId: 'custom-language-session',
        userPrompt: "comment s'appelle mon pote?",
      );
      expect(delegate.lastSystemPrompt, fixedItalian);
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
