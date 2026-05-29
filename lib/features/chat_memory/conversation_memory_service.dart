import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/inference/prompt_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/rolling_context_builder.dart';
import 'package:ai_orchestrator/features/semantic_index/semantic_workspace_index.dart';
import 'package:ai_orchestrator/features/semantic_index/workspace_embedding_service.dart';
import 'package:flutter/foundation.dart';

class ConversationContextSnapshot {
  const ConversationContextSnapshot({
    required this.contextLines,
    required this.contextTurns,
    required this.recalledLines,
  });

  final List<String> contextLines;
  final List<PromptTurn> contextTurns;
  final List<String> recalledLines;
}

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

  Future<ConversationContextSnapshot> buildContext({
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
      '[MEMORY_WINDOW] session=$sessionId lines=${result.contextLines.length} trimmed=${result.trimmedLines} total_chars=${result.totalChars}',
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
      '[CONTEXT_REBUILD] session=$sessionId context_lines=${result.contextLines.length} recall_lines=${recalled.length}',
    );
    return ConversationContextSnapshot(
      contextLines: result.contextLines,
      contextTurns: result.contextTurns,
      recalledLines: result.recalledLines,
    );
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
    final semanticText = '$role: $normalized';
    final embedding = await _embeddingService.embedTextAsync(semanticText);
    final workspaceId = _workspaceId(sessionId);
    await _semanticWorkspaceIndex.upsertChunk(
      workspaceId: workspaceId,
      documentPath: 'chat://$sessionId/$messageId',
      chunkIndex: timestamp,
      chunkText: semanticText,
      vector: embedding,
    );
    debugPrint(
      '[EMBEDDING_STORE] scope=chat session=$sessionId message=$messageId dims=${embedding.length}',
    );
  }

  Future<List<String>> recallRelevantMessages({
    required String sessionId,
    required String query,
    int topK = 4,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const <String>[];

    final queryVector = await _embeddingService.embedTextAsync(normalized);
    final matches = await _semanticWorkspaceIndex.search(
      queryVector: queryVector,
      workspaceId: _workspaceId(sessionId),
      topK: topK,
    );
    debugPrint(
      '[SEMANTIC_RETRIEVE] scope=chat session=$sessionId top_k=$topK matches=${matches.length}',
    );
    final recalled = <String>[];
    final seen = <String>{};
    for (final match in matches) {
      final value = match.chunkText.trim();
      if (value.isEmpty) continue;
      if (!seen.add(value)) continue;
      recalled.add(value);
    }
    debugPrint(
      '[MEMORY_RECALL] session=$sessionId recalled_lines=${recalled.length}',
    );
    return recalled;
  }

  String _workspaceId(String sessionId) => 'chat_memory:$sessionId';
}
