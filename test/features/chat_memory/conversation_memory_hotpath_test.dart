import 'dart:async';

import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat_memory/conversation_memory_service.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/token_estimator.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';
import 'package:ai_orchestrator/features/chat_memory/rolling_context_builder.dart';
import 'package:ai_orchestrator/features/semantic_index/semantic_workspace_index.dart';
import 'package:ai_orchestrator/features/semantic_index/workspace_embedding_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FailIfQueriedSemanticIndex extends SemanticWorkspaceIndex {
  _FailIfQueriedSemanticIndex()
      : super(databaseHelper: DatabaseHelper.instance);

  @override
  Future<List<SemanticChunkMatch>> search({
    required List<double> queryVector,
    String? workspaceId,
    int topK = 6,
  }) {
    throw StateError('semantic recall must not run on the response hot path');
  }
}

class _FailIfQueriedEmbeddingService extends WorkspaceEmbeddingService {
  const _FailIfQueriedEmbeddingService();

  @override
  Future<List<double>> embedTextAsync(String text) {
    throw StateError('query embedding must not run on the response hot path');
  }
}

class _BlockingEmbeddingService extends WorkspaceEmbeddingService {
  _BlockingEmbeddingService();

  final Completer<List<double>> blocker = Completer<List<double>>();
  int calls = 0;

  @override
  Future<List<double>> embedTextAsync(String text) {
    calls++;
    return blocker.future;
  }
}

class _RecordingSemanticIndex extends SemanticWorkspaceIndex {
  _RecordingSemanticIndex() : super(databaseHelper: DatabaseHelper.instance);

  int upsertCalls = 0;
  int clearCalls = 0;

  @override
  Future<void> upsertChunk({
    required String workspaceId,
    required String documentPath,
    String? documentTitle,
    required int chunkIndex,
    required String chunkText,
    required List<double> vector,
  }) async {
    upsertCalls++;
  }

  @override
  Future<void> clearWorkspace(String workspaceId) async {
    clearCalls++;
  }
}

ConversationMemoryService _createService({
  required SemanticWorkspaceIndex semanticIndex,
  required WorkspaceEmbeddingService embeddingService,
}) {
  return ConversationMemoryService(
    rollingContextBuilder: RollingContextBuilder(
      windowManager: MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.standard(isWeb: false),
      ),
    ),
    semanticWorkspaceIndex: semanticIndex,
    embeddingService: embeddingService,
  );
}

void main() {
  test('buildContext does not execute semantic recall that the builder ignores',
      () async {
    final service = _createService(
      semanticIndex: _FailIfQueriedSemanticIndex(),
      embeddingService: const _FailIfQueriedEmbeddingService(),
    );

    final context = await service.buildContext(
      sessionId: 'assistant-hotpath',
      messages: const <ChatMessage>[
        ChatMessage(
          id: 'u1',
          sessionId: 'assistant-hotpath',
          role: 'user',
          content: 'prima domanda',
          timestamp: 1,
        ),
        ChatMessage(
          id: 'a1',
          sessionId: 'assistant-hotpath',
          role: 'assistant',
          content: 'prima risposta',
          timestamp: 2,
        ),
      ],
      userPrompt: 'continua',
    );

    expect(
      context,
      const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'prima domanda'),
        ChatTurn(role: ChatRole.assistant, content: 'prima risposta'),
      ],
    );
  });

  test('storeMessageEmbedding returns after queueing instead of awaiting work',
      () async {
    final embedding = _BlockingEmbeddingService();
    final index = _RecordingSemanticIndex();
    final service = _createService(
      semanticIndex: index,
      embeddingService: embedding,
    );

    await service
        .storeMessageEmbedding(
          sessionId: 'assistant-hotpath',
          messageId: 'u1',
          role: 'user',
          content: 'messaggio da indicizzare',
          timestamp: 1,
        )
        .timeout(const Duration(milliseconds: 100));

    await pumpEventQueue();
    expect(embedding.calls, 1);
    expect(index.upsertCalls, 0);

    embedding.blocker.complete(const <double>[1, 0, 0]);
    await pumpEventQueue();

    expect(index.upsertCalls, 1);
  });

  test('clear invalidates an embedding still in flight before index mutation',
      () async {
    final embedding = _BlockingEmbeddingService();
    final index = _RecordingSemanticIndex();
    final service = _createService(
      semanticIndex: index,
      embeddingService: embedding,
    );

    await service.storeMessageEmbedding(
      sessionId: 'assistant-clear',
      messageId: 'u1',
      role: 'user',
      content: 'dato da cancellare',
      timestamp: 1,
    );
    await pumpEventQueue();
    expect(embedding.calls, 1);

    final clearFuture = service.clearSessionMemory('assistant-clear');
    await pumpEventQueue();

    expect(index.clearCalls, 0);
    expect(index.upsertCalls, 0);

    embedding.blocker.complete(const <double>[1, 0, 0]);
    await clearFuture;

    expect(index.upsertCalls, 0);
    expect(index.clearCalls, 1);
  });
}
