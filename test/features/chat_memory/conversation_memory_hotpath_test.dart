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

void main() {
  test('buildContext does not execute semantic recall that the builder ignores',
      () async {
    final service = ConversationMemoryService(
      rollingContextBuilder: RollingContextBuilder(
        windowManager: MemoryWindowManager(
          tokenEstimator: const CharacterLengthEstimator(),
          configProvider: () => MemoryWindowConfig.standard(isWeb: false),
        ),
      ),
      semanticWorkspaceIndex: _FailIfQueriedSemanticIndex(),
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
}
