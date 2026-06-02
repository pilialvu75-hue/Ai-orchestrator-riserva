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
    List<ChatTurn> recalledContext = const <ChatTurn>[],
  }) {
    final seen = <String>{};
    final turns = <ChatTurn>[];

    // 1. Inject recalled context FIRST (semantic memory)
    for (final recalled in recalledContext) {
      final normalized = _normalizer.normalize(recalled);
      if (normalized.content.isEmpty) continue;
      if (!seen.add(_turnKey(normalized))) continue;
      turns.add(normalized);
    }

    // 2. Inject conversation history (chronological truth)
    for (final message in messages) {
      if (excludedMessageId != null && message.id == excludedMessageId) continue;

      final turn = _normalizer.normalize(
        ChatTurn(
          role: _parseRole(message.role),
          content: message.content,
        ),
      );
      if (turn.content.isEmpty) continue;
      if (!seen.add(_turnKey(turn))) continue;
      turns.add(turn);
    }

    final result = _windowManager.trimToWindow(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      contextTurns: turns,
    );

    return RollingContextResult(
      contextTurns: result.contextTurns,
      trimmedLines: result.trimmedLines,
      overflowDetected: result.overflowDetected,
      totalChars: result.totalChars,
    );
  }

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

  String _turnKey(ChatTurn turn) =>
      '${turn.role.name}:${turn.content.trim().toLowerCase()}';
}
