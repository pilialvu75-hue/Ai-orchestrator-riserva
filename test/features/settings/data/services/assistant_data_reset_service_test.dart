import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:ai_orchestrator/core/memory/context_window_manager.dart';
import 'package:ai_orchestrator/features/chat_memory/conversation_memory_service.dart';
import 'package:ai_orchestrator/features/chat_memory/rolling_context_builder.dart';
import 'package:ai_orchestrator/features/semantic_index/semantic_workspace_index.dart';
import 'package:ai_orchestrator/features/semantic_index/workspace_embedding_service.dart';
import 'package:ai_orchestrator/features/settings/data/services/assistant_data_reset_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockDatabaseHelper extends Mock implements DatabaseHelper {}

class _MockContextWindowManager extends Mock implements ContextWindowManager {}

class _MockRollingContextBuilder extends Mock implements RollingContextBuilder {}

class _MockSemanticWorkspaceIndex extends Mock
    implements SemanticWorkspaceIndex {}

class _MockWorkspaceEmbeddingService extends Mock
    implements WorkspaceEmbeddingService {}

void main() {
  late _MockDatabaseHelper database;
  late _MockContextWindowManager contextWindow;
  late AssistantDataResetService service;

  setUp(() {
    database = _MockDatabaseHelper();
    contextWindow = _MockContextWindowManager();

    final conversationMemory = ConversationMemoryService(
      rollingContextBuilder: _MockRollingContextBuilder(),
      semanticWorkspaceIndex: _MockSemanticWorkspaceIndex(),
      embeddingService: _MockWorkspaceEmbeddingService(),
    );

    service = AssistantDataResetService(
      databaseHelper: database,
      conversationMemoryService: conversationMemory,
      contextWindowManager: contextWindow,
    );
  });

  test('global reset erases every Assistant memory category only', () async {
    when(() => database.deleteAllChatMessages())
        .thenAnswer((_) async => 12);
    when(() => database.deleteAllChatSemanticMemory())
        .thenAnswer((_) async => 10);
    when(
      () => database.deletePreferencesWithPrefix(
        AssistantDurableMemoryStore.storagePrefix,
      ),
    ).thenAnswer((_) async => 4);
    when(() => database.deleteAllProjectMemories())
        .thenAnswer((_) async => 3);

    final report = await service.reset(
      const AssistantDataResetSelection.all(),
    );

    expect(report.complete, isTrue);
    expect(report.partial, isFalse);
    expect(
      report.outcomeFor(AssistantDataResetCategory.chatHistory)?.removedItems,
      12,
    );
    expect(
      report
          .outcomeFor(AssistantDataResetCategory.semanticChatIndex)
          ?.removedItems,
      10,
    );
    expect(
      report.outcomeFor(AssistantDataResetCategory.durableMemory)?.removedItems,
      4,
    );
    expect(
      report.outcomeFor(AssistantDataResetCategory.projectMemory)?.removedItems,
      3,
    );

    verify(() => contextWindow.startNewSession()).called(1);
    verify(() => database.deleteAllChatMessages()).called(1);
    verify(() => database.deleteAllChatSemanticMemory()).called(1);
    verify(
      () => database.deletePreferencesWithPrefix(
        AssistantDurableMemoryStore.storagePrefix,
      ),
    ).called(1);
    verify(() => database.deleteAllProjectMemories()).called(1);
  });

  test('selected reset leaves unselected categories untouched', () async {
    when(() => database.deleteAllChatMessages())
        .thenAnswer((_) async => 2);

    final report = await service.reset(
      const AssistantDataResetSelection(
        chatHistory: true,
      ),
    );

    expect(report.complete, isTrue);
    expect(report.outcomes, hasLength(1));
    expect(
      report.outcomes.single.category,
      AssistantDataResetCategory.chatHistory,
    );

    verify(() => database.deleteAllChatMessages()).called(1);
    verifyNever(() => database.deleteAllChatSemanticMemory());
    verifyNever(() => database.deleteAllProjectMemories());
    verifyNever(
      () => database.deletePreferencesWithPrefix(any()),
    );
    verifyNever(() => contextWindow.startNewSession());
  });

  test('partial failure is explicit and later categories are still reported',
      () async {
    when(() => database.deleteAllChatMessages())
        .thenAnswer((_) async => 5);
    when(
      () => database.deletePreferencesWithPrefix(
        AssistantDurableMemoryStore.storagePrefix,
      ),
    ).thenThrow(StateError('durable store unavailable'));
    when(() => database.deleteAllProjectMemories())
        .thenAnswer((_) async => 1);

    final report = await service.reset(
      const AssistantDataResetSelection(
        chatHistory: true,
        durableMemory: true,
        projectMemory: true,
      ),
    );

    expect(report.complete, isFalse);
    expect(report.partial, isTrue);
    expect(
      report.outcomeFor(AssistantDataResetCategory.chatHistory)?.success,
      isTrue,
    );
    expect(
      report.outcomeFor(AssistantDataResetCategory.durableMemory)?.success,
      isFalse,
    );
    expect(
      report.outcomeFor(AssistantDataResetCategory.durableMemory)?.error,
      contains('durable store unavailable'),
    );
    expect(
      report.outcomeFor(AssistantDataResetCategory.projectMemory)?.success,
      isTrue,
    );
  });

  test('empty reset selection is rejected before touching storage', () async {
    await expectLater(
      service.reset(const AssistantDataResetSelection()),
      throwsArgumentError,
    );

    verifyNever(() => database.deleteAllChatMessages());
    verifyNever(() => database.deleteAllChatSemanticMemory());
    verifyNever(() => database.deleteAllProjectMemories());
    verifyNever(
      () => database.deletePreferencesWithPrefix(any()),
    );
    verifyNever(() => contextWindow.startNewSession());
  });
}
