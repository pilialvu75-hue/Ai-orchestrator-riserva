import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn_normalizer.dart';
import 'package:ai_orchestrator/features/chat_memory/rolling_context_builder.dart';
import 'package:ai_orchestrator/features/semantic_index/semantic_workspace_index.dart';
import 'package:ai_orchestrator/features/semantic_index/workspace_embedding_service.dart';
import 'package:flutter/foundation.dart';

class ConversationMemoryService {
  const ConversationMemoryService({
    required RollingContextBuilder rollingContextBuilder,
    required SemanticWorkspaceIndex semanticWorkspaceIndex,
    required WorkspaceEmbeddingService embeddingService,
  })  : _rollingContextBuilder = rollingContextBuilder,
        _semanticWorkspaceIndex = semanticWorkspaceIndex,
        _embeddingService = embeddingService;

  final RollingContextBuilder _rollingContextBuilder;
  final SemanticWorkspaceIndex _semanticWorkspaceIndex;
  final WorkspaceEmbeddingService _embeddingService;
  static const ChatTurnNormalizer _normalizer = ChatTurnNormalizer();

  Future<List<ChatTurn>> buildContext({
    required String sessionId,
    required List<ChatMessage> messages,
    required String userPrompt,
    String? systemPrompt,
    String? excludedMessageId,
  }) async {
    final recalled = await recallRelevantMessages(
      sessionId: sessionId,
      query: userPrompt,
      topK: 4,
    );

    final result = _rollingContextBuilder.build(
      messages: messages,
      userPrompt: userPrompt,
      systemPrompt: systemPrompt,
      excludedMessageId: excludedMessageId,
      recalledContext: recalled,
    );

    debugPrint(
      '[MEMORY_WINDOW] session=$sessionId turns=${result.contextTurns.length} trimmed=${result.trimmedLines} total_chars=${result.totalChars}',
    );

    if (result.trimmedLines > 0) {
      debugPrint(
        '[MEMORY_TRIM] session=$sessionId trimmed_lines=${result.trimmedLines}',
      );
    }

    if (result.overflowDetected) {
      debugPrint('[CONTEXT_OVERFLOW] session=$sessionId detected=true');
    }

    debugPrint(
      '[CONTEXT_REBUILD] session=$sessionId context_turns=${result.contextTurns.length} recall_turns=${recalled.length}',
    );

    return List<ChatTurn>.unmodifiable(result.contextTurns);
  }

  Future<void> storeMessageEmbedding({
    required String sessionId,
    required String messageId,
    required String role,
    required String content,
    required int timestamp,
  }) async {
    final normalized = content.trim();

    if (normalized.isEmpty) return;

    final turnRole = _parseRole(role);
    final semanticText = normalized;
    final embedding = await _embeddingService.embedTextAsync(semanticText);

    final workspaceId = _workspaceId(sessionId);

    await _semanticWorkspaceIndex.upsertChunk(
      workspaceId: workspaceId,
      documentPath: 'chat://$sessionId/$messageId',
      documentTitle: turnRole.name,
      chunkIndex: timestamp,
      chunkText: semanticText,
      vector: embedding,
    );

    debugPrint(
      '[EMBEDDING_STORE] scope=chat session=$sessionId message=$messageId role=${turnRole.name} dims=${embedding.length}',
    );
  }

  Future<List<ChatTurn>> recallRelevantMessages({
    required String sessionId,
    required String query,
    int topK = 4,
  }) async {
    final normalized = query.trim();

    if (normalized.isEmpty) {
      return const <ChatTurn>[];
    }

    final queryVector = await _embeddingService.embedTextAsync(normalized);

    final matches = await _semanticWorkspaceIndex.search(
      queryVector: queryVector,
      workspaceId: _workspaceId(sessionId),
      topK: topK,
    );

    debugPrint(
      '[SEMANTIC_RETRIEVE] scope=chat session=$sessionId top_k=$topK matches=${matches.length}',
    );

    final recalled = <ChatTurn>[];
    final seen = <String>{};

    for (final match in matches) {
      final normalizedContent = _normalizer.normalizeContent(
        match.chunkText,
        fallbackRole: _roleFromMetadata(match.documentTitle),
      );

      if (normalizedContent.isEmpty) continue;

      final turn = ChatTurn(
        role: _roleFromMetadata(match.documentTitle),
        content: normalizedContent,
      );

      if (turn.content.toLowerCase() == normalized.toLowerCase()) {
        continue;
      }

      if (!seen.add('${turn.role.name}:${turn.content.toLowerCase()}')) {
        continue;
      }

      recalled.add(turn);
    }

    debugPrint(
      '[MEMORY_RECALL] session=$sessionId recalled_turns=${recalled.length}',
    );

    return recalled;
  }

  Future<void> clearSessionMemory(String sessionId) {
    return _semanticWorkspaceIndex.clearWorkspace(_workspaceId(sessionId));
  }

  String _workspaceId(String sessionId) => 'chat_memory:$sessionId';

  ChatRole _parseRole(String role) {
    switch (role.trim().toLowerCase()) {
      case 'assistant':
        return ChatRole.assistant;
      case 'system':
        return ChatRole.system;
      case 'user':
      default:
        return ChatRole.user;
    }
  }

  ChatRole _roleFromMetadata(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'assistant':
        return ChatRole.assistant;
      case 'system':
        return ChatRole.system;
      case 'user':
      default:
        return ChatRole.user;
    }
  }
}
