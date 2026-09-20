import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/inference/conversation_context_limits.dart';
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
    }

    final result = _windowManager.trimToWindow(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      contextTurns: turns,
      // Do not discard conversational turns using a character heuristic before
      // the runtime/provider is known. The selected backend owns its capacity:
      // Android local uses exact llama.cpp tokens; legacy local and Cloud apply
      // their own provider-specific bounds.
      enforceEstimatedSizeBudget: false,
    );

    if (recalledContext.isEmpty) {
      return RollingContextResult(
        contextTurns: result.contextTurns,
        trimmedLines: result.trimmedLines,
        overflowDetected: result.overflowDetected,
        totalChars: result.totalSize,
      );
    }

    // Conditional recall must be composed against the same portable recent
    // envelope that will actually be forwarded cross-runtime. Comparing recall
    // against the entire unbounded recent history would incorrectly classify
    // older recalled exchanges as duplicates and then return the full history.
    final portableRecent = _recentTailFromUserBoundary(
      result.contextTurns,
      maxTurns: ConversationContextLimits.safeCrossRuntimeTurns,
    );

    final normalizedRecall = _normalizeRecalledPairs(
      recalledContext,
      recentContext: portableRecent,
    );
    final recalledPairs = normalizedRecall.length >
            ConversationContextLimits.safeCrossRuntimeTurns
        ? List<ChatTurn>.unmodifiable(
            normalizedRecall.sublist(
              normalizedRecall.length -
                  ConversationContextLimits.safeCrossRuntimeTurns,
            ),
          )
        : normalizedRecall;

    final recentBudget =
        ConversationContextLimits.safeCrossRuntimeTurns - recalledPairs.length;
    final recentForRecall = _recentTailFromUserBoundary(
      result.contextTurns,
      maxTurns: recentBudget,
    );

    final merged = List<ChatTurn>.unmodifiable(<ChatTurn>[
      ...recalledPairs,
      ...recentForRecall,
    ]);

    final recalledChars = recalledPairs.fold<int>(
      0,
      (sum, turn) => sum + turn.content.length,
    );
    final droppedRecentTurns =
        result.contextTurns.length - recentForRecall.length;
    final droppedRecentChars = result.contextTurns
        .take(droppedRecentTurns)
        .fold<int>(0, (sum, turn) => sum + turn.content.length);
    final adjustedTotalChars =
        result.totalSize - droppedRecentChars + recalledChars;

    return RollingContextResult(
      contextTurns: merged,
      trimmedLines: result.trimmedLines + droppedRecentTurns,
      overflowDetected: result.overflowDetected,
      totalChars: adjustedTotalChars > 0 ? adjustedTotalChars : 0,
    );
  }

  List<ChatTurn> _recentTailFromUserBoundary(
    List<ChatTurn> recentContext, {
    required int maxTurns,
  }) {
    if (maxTurns <= 0 || recentContext.isEmpty) {
      return const <ChatTurn>[];
    }

    var start = recentContext.length > maxTurns
        ? recentContext.length - maxTurns
        : 0;

    // A portable recalled bundle must remain conversationally coherent. If a
    // raw tail boundary lands on an assistant turn, advance to the next user
    // turn rather than injecting an orphaned answer.
    while (start < recentContext.length &&
        recentContext[start].role == ChatRole.assistant) {
      start++;
    }

    if (start >= recentContext.length) {
      return const <ChatTurn>[];
    }

    return List<ChatTurn>.unmodifiable(recentContext.sublist(start));
  }

  List<ChatTurn> _normalizeRecalledPairs(
    List<ChatTurn> recalledContext, {
    required List<ChatTurn> recentContext,
  }) {
    if (recalledContext.isEmpty) {
      return const <ChatTurn>[];
    }

    final recentKeys = recentContext.map(_turnKey).toSet();
    final recalledKeys = <String>{};
    final selected = <ChatTurn>[];
    ChatTurn? pendingUser;

    for (final raw in recalledContext) {
      final normalized = _normalizer.normalize(raw);
      if (normalized.content.isEmpty || normalized.role == ChatRole.system) {
        continue;
      }

      if (normalized.role == ChatRole.user) {
        pendingUser = normalized;
        continue;
      }

      final user = pendingUser;
      if (user == null || normalized.role != ChatRole.assistant) {
        continue;
      }
      pendingUser = null;

      final userKey = _turnKey(user);
      final assistantKey = _turnKey(normalized);

      // A recalled exchange is all-or-nothing. If either side already belongs
      // to the recent rolling window, skip the whole pair rather than creating
      // a duplicate or an orphaned answer.
      if (recentKeys.contains(userKey) ||
          recentKeys.contains(assistantKey) ||
          recalledKeys.contains(userKey) ||
          recalledKeys.contains(assistantKey)) {
        continue;
      }

      selected
        ..add(user)
        ..add(normalized);
      recalledKeys
        ..add(userKey)
        ..add(assistantKey);
    }

    return List<ChatTurn>.unmodifiable(selected);
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

  String _turnKey(ChatTurn turn) =>
      '${turn.role.name}:${turn.content.trim().toLowerCase()}';
}
