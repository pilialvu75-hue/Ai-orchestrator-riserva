import 'dart:async';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn_normalizer.dart';
import 'package:ai_orchestrator/features/chat_memory/rolling_context_builder.dart';
import 'package:ai_orchestrator/features/semantic_index/semantic_workspace_index.dart';
import 'package:ai_orchestrator/features/semantic_index/workspace_embedding_service.dart';
import 'package:flutter/foundation.dart';

class ConversationMemoryService {
  ConversationMemoryService({
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

  /// Per-session indexing tail.
  ///
  /// ChatRepository awaits [storeMessageEmbedding], but the method only queues
  /// work and returns immediately. Actual embedding/database work therefore no
  /// longer delays inference startup while ordering is still deterministic.
  final Map<String, Future<void>> _indexingTails = <String, Future<void>>{};

  /// Incremented before a session is cleared. Queued work captures the current
  /// epoch and becomes stale as soon as a clear starts.
  final Map<String, int> _indexEpochs = <String, int>{};

  /// New writes are ignored while a clear is draining the previous queue.
  final Set<String> _clearingSessions = <String>{};

  /// Coalesces concurrent clear requests for the same session.
  final Map<String, Future<void>> _clearOperations = <String, Future<void>>{};

  Future<List<ChatTurn>> buildContext({
    required String sessionId,
    required List<ChatMessage> messages,
    required String userPrompt,
    String? systemPrompt,
    String? excludedMessageId,
  }) async {
    // Semantic recall is intentionally not executed on the response hot path
    // while RollingContextBuilder does not consume recalledContext. Running an
    // embedding + database scan here added latency without changing the prompt
    // sent to the model. The recall API and stored embeddings remain available
    // for the later chronological relevance-aware memory policy.
    const recalled = <ChatTurn>[];

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
      '[CONTEXT_REBUILD] session=$sessionId context_turns=${result.contextTurns.length} recall_turns=0 recall_mode=deferred',
    );

    return result.contextTurns;
  }

  /// Queues semantic indexing without delaying the response hot path.
  ///
  /// Errors are contained and logged inside the queue because callers no
  /// longer wait for the database operation itself.
  void storeMessageEmbeddingAsync({
    required String sessionId,
    required String messageId,
    required String role,
    required String content,
    required int timestamp,
  }) {
    unawaited(
      storeMessageEmbedding(
        sessionId: sessionId,
        messageId: messageId,
        role: role,
        content: content,
        timestamp: timestamp,
      ),
    );
  }

  /// Enqueues semantic indexing and returns as soon as the work is scheduled.
  ///
  /// This preserves the existing Future-based API used by ChatRepository while
  /// removing embedding/vector-index work from the pre-first-token path.
  Future<void> storeMessageEmbedding({
    required String sessionId,
    required String messageId,
    required String role,
    required String content,
    required int timestamp,
  }) async {
    final normalized = content.trim();

    if (normalized.isEmpty) return;

    if (_clearingSessions.contains(sessionId)) {
      debugPrint(
        '[EMBEDDING_STORE_SKIPPED] session=$sessionId message=$messageId reason=session_clearing',
      );
      return;
    }

    final epoch = _indexEpochs[sessionId] ?? 0;
    final previous = _indexingTails[sessionId] ?? Future<void>.value();

    late final Future<void> scheduled;
    scheduled = previous
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint(
            '[EMBEDDING_QUEUE_PREVIOUS_ERROR] session=$sessionId error=$error',
          );
        })
        .then((_) async {
          if (_isIndexWriteStale(sessionId, epoch)) {
            return;
          }

          final turnRole = ChatTurnNormalizer.roleFromText(role);
          final embedding = await _embeddingService.embedTextAsync(normalized);

          // clearSessionMemory may have started while the embedding was being
          // calculated. Re-check before mutating the semantic index.
          if (_isIndexWriteStale(sessionId, epoch)) {
            debugPrint(
              '[EMBEDDING_STORE_SKIPPED] session=$sessionId message=$messageId reason=stale_epoch',
            );
            return;
          }

          await _semanticWorkspaceIndex.upsertChunk(
            workspaceId: _workspaceId(sessionId),
            documentPath: 'chat://$sessionId/$messageId',
            documentTitle: turnRole.name,
            chunkIndex: timestamp,
            chunkText: normalized,
            vector: embedding,
          );

          debugPrint(
            '[EMBEDDING_STORE] scope=chat session=$sessionId message=$messageId role=${turnRole.name} dims=${embedding.length}',
          );
        })
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint(
            '[EMBEDDING_STORE_ASYNC_ERROR] session=$sessionId message=$messageId error=$error',
          );
        });

    _indexingTails[sessionId] = scheduled;

    unawaited(
      scheduled.whenComplete(() {
        if (identical(_indexingTails[sessionId], scheduled)) {
          _indexingTails.remove(sessionId);
        }
      }),
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

    final workspaceId = _workspaceId(sessionId);

    try {
      final queryVector = await _embeddingService.embedTextAsync(normalized);

      final matches = await _semanticWorkspaceIndex.search(
        queryVector: queryVector,
        workspaceId: workspaceId,
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
    } catch (e) {
      debugPrint('[MEMORY_RECALL_ERROR] session=$sessionId error=$e');
      return const <ChatTurn>[];
    }
  }

  Future<void> clearSessionMemory(String sessionId) {
    final existing = _clearOperations[sessionId];
    if (existing != null) return existing;

    late final Future<void> operation;
    operation = _clearSessionMemoryInternal(sessionId).whenComplete(() {
      if (identical(_clearOperations[sessionId], operation)) {
        _clearOperations.remove(sessionId);
      }
    });

    _clearOperations[sessionId] = operation;
    return operation;
  }

  Future<void> _clearSessionMemoryInternal(String sessionId) async {
    _clearingSessions.add(sessionId);
    _indexEpochs[sessionId] = (_indexEpochs[sessionId] ?? 0) + 1;

    try {
      // Drain any work already in flight. The epoch increment makes queued
      // operations skip their upsert after an outstanding embedding returns.
      final pending = _indexingTails[sessionId];
      if (pending != null) {
        await pending;
      }

      await _semanticWorkspaceIndex.clearWorkspace(_workspaceId(sessionId));
    } finally {
      _indexingTails.remove(sessionId);
      _clearingSessions.remove(sessionId);
    }
  }

  bool _isIndexWriteStale(String sessionId, int expectedEpoch) {
    return _clearingSessions.contains(sessionId) ||
        (_indexEpochs[sessionId] ?? 0) != expectedEpoch;
  }

  String _workspaceId(String sessionId) => 'chat_memory:$sessionId';

  ChatRole _roleFromMetadata(String? value) {
    return ChatTurnNormalizer.roleFromText(value);
  }
}
