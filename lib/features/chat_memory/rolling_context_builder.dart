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
    final normalizedContent = _normalizeContent(content);
    if (normalizedContent == null || role == ChatRole.system) {
      return null;
    }
    return ChatTurn(role: role, content: normalizedContent);
  }

  ChatTurn? _normalizeContextTurn(ChatTurn turn) {
    final normalizedContent = _normalizeContent(turn.content);
    if (normalizedContent == null) return null;
    return normalizedContent == turn.content
        ? turn
        : turn.copyWith(content: normalizedContent);
  }

  String _turnSignature(ChatTurn turn) {
    final buffer = StringBuffer()
      ..write(turn.role.index)
      ..write(':')
      ..write(turn.excludeFromContext ? 1 : 0)
      ..write(':')
      ..write(turn.content.length)
      ..write(':')
      ..write(turn.content);
    return buffer.toString();
  }

  String? _normalizeContent(String content) {
    final normalized = content.trim();
    return normalized.isEmpty ? null : normalized;
  }
}
