import 'dart:convert';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn_normalizer.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';

class RollingContextResult {
  const RollingContextResult({
    required this.contextTurns,
    required this.trimmedLines,
    required this.overflowDetected,
    required this.totalChars,
  });

  final List<ChatTurn> contextTurns;
  final int trimmedLines;
  final bool overflowDetected;
  final int totalChars;
}

class RollingContextBuilder {
  const RollingContextBuilder({
    required MemoryWindowManager windowManager,
  }) : _windowManager = windowManager;

  final MemoryWindowManager _windowManager;
  static const ChatTurnNormalizer _normalizer = ChatTurnNormalizer();

  RollingContextResult build({
    required List<ChatMessage> messages,
    required String userPrompt,
    String? systemPrompt,
    String? excludedMessageId,
    List<ChatTurn> recalledContext = const [],
  }) {
    final turns = <ChatTurn>[];
    final historySignatures = <String>{};

    for (final message in messages) {
      if (excludedMessageId != null && message.id == excludedMessageId) {
        continue;
      }
      final turn = _normalizeConversationTurn(
        role: ChatTurnNormalizer.roleFromText(message.role),
        content: message.content,
      );
      if (turn == null) continue;
      turns.add(turn);
      historySignatures.add(_turnSignature(turn));
    }

    final normalizedRecalledTurns = recalledContext
        .map(_normalizeContextTurn)
        .whereType<ChatTurn>()
        .toList(growable: false);
    final recalledSignatures = <String>{};
    final filteredRecalledTurns = <ChatTurn>[];
    for (final turn in normalizedRecalledTurns) {
      final signature = _turnSignature(turn);
      if (historySignatures.contains(signature)) continue;
      if (!recalledSignatures.add(signature)) continue;
      filteredRecalledTurns.add(turn);
    }
    turns.addAll(filteredRecalledTurns);

    final result = _windowManager.trimToWindow(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      contextTurns: turns,
    );

    return RollingContextResult(
      contextTurns: result.contextTurns,
      trimmedLines: result.trimmedLines,
      overflowDetected: result.overflowDetected,
      totalChars: result.totalSize,
    );
  }

  ChatTurn? _normalizeConversationTurn({
    required ChatRole role,
    required String content,
  }) {
    final normalized = _normalizer.normalize(
      ChatTurn(role: role, content: content),
    );
    if (normalized.content.isEmpty || normalized.role == ChatRole.system) {
      return null;
    }
    return normalized;
  }

  ChatTurn? _normalizeContextTurn(ChatTurn turn) {
    final normalizedContent = turn.content.trim();
    if (normalizedContent.isEmpty) return null;
    return normalizedContent == turn.content
        ? turn
        : turn.copyWith(content: normalizedContent);
  }

  String _turnSignature(ChatTurn turn) {
    return jsonEncode([
      turn.role.index,
      turn.excludeFromContext,
      turn.content,
    ]);
  }
}
