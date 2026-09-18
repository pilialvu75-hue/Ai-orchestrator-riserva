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

class _RecallEmbeddingService extends WorkspaceEmbeddingService {
  const _RecallEmbeddingService();

  static int calls = 0;

  @override
  Future<List<double>> embedTextAsync(String text) async {
    calls++;
    return const <double>[1, 0, 0];
  }
}

class _RecallSemanticIndex extends SemanticWorkspaceIndex {
  _RecallSemanticIndex({
    required this.matches,
  }) : super(databaseHelper: DatabaseHelper.instance);

  final List<SemanticChunkMatch> matches;
  int searchCalls = 0;

  @override
  Future<List<SemanticChunkMatch>> search({
    required List<double> queryVector,
    String? workspaceId,
    int topK = 6,
  }) async {
    searchCalls++;
    return matches.take(topK).toList(growable: false);
  }
}

ConversationMemoryService _service(_RecallSemanticIndex index) {
  return ConversationMemoryService(
    rollingContextBuilder: RollingContextBuilder(
      windowManager: MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.custom(
          maxContextLines: 16,
          maxTotalSize: 512,
          isWeb: false,
        ),
      ),
    ),
    semanticWorkspaceIndex: index,
    embeddingService: const _RecallEmbeddingService(),
  );
}

List<ChatMessage> _conversation() {
  final messages = <ChatMessage>[];
  for (var pair = 1; pair <= 10; pair++) {
    messages.add(
      ChatMessage(
        id: 'u$pair',
        sessionId: 'recall-session',
        role: 'user',
        content: pair == 1
            ? 'Usiamo Phi 3.5 come modello locale'
            : 'domanda $pair',
        timestamp: pair * 2 - 1,
      ),
    );
    messages.add(
      ChatMessage(
        id: 'a$pair',
        sessionId: 'recall-session',
        role: 'assistant',
        content: pair == 1
            ? 'Decisione registrata: Phi 3.5.'
            : 'risposta $pair',
        timestamp: pair * 2,
      ),
    );
  }
  return messages;
}

void main() {
  setUp(() {
    _RecallEmbeddingService.calls = 0;
  });

  test('ordinary prompt does not execute semantic recall', () async {
    final index = _RecallSemanticIndex(matches: const <SemanticChunkMatch>[]);
    final service = _service(index);

    final context = await service.buildContext(
      sessionId: 'recall-session',
      messages: _conversation(),
      userPrompt: 'Continua con il prossimo punto.',
    );

    expect(context, hasLength(16));
    expect(index.searchCalls, 0);
    expect(_RecallEmbeddingService.calls, 0);
  });

  test('explicit old-reference recall replaces old edge of recent window', () async {
    final index = _RecallSemanticIndex(
      matches: const <SemanticChunkMatch>[
        SemanticChunkMatch(
          documentPath: 'chat://recall-session/u1',
          documentTitle: 'user',
          chunkIndex: 1,
          chunkText: 'Usiamo Phi 3.5 come modello locale',
          score: 0.88,
        ),
      ],
    );
    final service = _service(index);

    final context = await service.buildContext(
      sessionId: 'recall-session',
      messages: _conversation(),
      userPrompt: 'Ti ricordi quale modello locale avevamo deciso di usare?',
    );

    expect(index.searchCalls, 1);
    expect(_RecallEmbeddingService.calls, 1);
    expect(context, hasLength(16));
    expect(
      context.take(2).toList(),
      const <ChatTurn>[
        ChatTurn(
          role: ChatRole.user,
          content: 'Usiamo Phi 3.5 come modello locale',
        ),
        ChatTurn(
          role: ChatRole.assistant,
          content: 'Decisione registrata: Phi 3.5.',
        ),
      ],
    );
    expect(
      context,
      contains(const ChatTurn(role: ChatRole.user, content: 'domanda 10')),
    );
    expect(
      context,
      isNot(contains(const ChatTurn(role: ChatRole.user, content: 'domanda 3'))),
    );
  });

  test('recall is skipped when all history already fits recent window', () async {
    final index = _RecallSemanticIndex(
      matches: const <SemanticChunkMatch>[
        SemanticChunkMatch(
          documentPath: 'chat://recall-session/u1',
          documentTitle: 'user',
          chunkIndex: 1,
          chunkText: 'Usiamo Phi 3.5 come modello locale',
          score: 0.9,
        ),
      ],
    );
    final service = _service(index);

    final context = await service.buildContext(
      sessionId: 'recall-session',
      messages: _conversation().take(6).toList(),
      userPrompt: 'Ti ricordi quale modello locale avevamo deciso di usare?',
    );

    expect(context, hasLength(6));
    expect(index.searchCalls, 0);
    expect(_RecallEmbeddingService.calls, 0);
  });
}
