import 'dart:math' as math;

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

class ChronologicalRecallMatch {
  const ChronologicalRecallMatch({
    required this.messageId,
    required this.score,
  });

  final String messageId;
  final double score;
}

class ChronologicalRecallResult {
  const ChronologicalRecallResult({
    required this.contextTurns,
    required this.recalledTurns,
    required this.recalledPairs,
    required this.droppedRecentTurns,
  });

  final List<ChatTurn> contextTurns;
  final int recalledTurns;
  final int recalledPairs;
  final int droppedRecentTurns;
}

/// Conservative long-range recall for explicit references to older conversation.
///
/// The normal recent chronological suffix remains authoritative. Semantic
/// retrieval is only allowed to replace a small number of the oldest recent
/// turns with complete older user -> assistant pairs, preserving chronology.
abstract final class ChronologicalLongRecall {
  static const double minimumScore = 0.30;
  static const int maxPairs = 2;

  static bool shouldAttempt(String userPrompt) {
    final prompt = userPrompt.trim().toLowerCase();
    if (prompt.isEmpty) return false;

    return _containsAny(prompt, const <String>[
      // Italian.
      'ti ricordi',
      'ricordi quando',
      'ricordi quale',
      'ricordi quali',
      'ricordi cosa',
      'ricordi che',
      'ricordi come',
      'avevamo deciso',
      'avevamo detto',
      'ne avevamo parlato',
      'come avevamo',
      'in precedenza avevamo',
      "l'altra volta",
      'la volta scorsa',
      // English.
      'do you remember',
      'remember when',
      'we decided',
      'we agreed',
      'we said before',
      'as we decided',
      'last time',
      // French.
      'tu te souviens',
      'souviens-toi',
      'on avait décidé',
      'nous avions décidé',
      'on avait dit',
      'la dernière fois',
      // Spanish.
      'te acuerdas',
      'recuerdas ',
      'habíamos decidido',
      'habiamos decidido',
      'habíamos dicho',
      'habiamos dicho',
      'la otra vez',
    ]);
  }

  static String semanticQuery(String userPrompt) {
    var query = userPrompt.trim();

    for (final cue in _queryCues) {
      query = query.replaceAll(
        RegExp(RegExp.escape(cue), caseSensitive: false),
        ' ',
      );
    }

    query = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    return query.length >= 3 ? query : userPrompt.trim();
  }

  static ChronologicalRecallResult merge({
    required List<ChatMessage> messages,
    required String? excludedMessageId,
    required List<ChatTurn> recentContext,
    required List<ChronologicalRecallMatch> matches,
  }) {
    if (recentContext.length < 4 || matches.isEmpty) {
      return ChronologicalRecallResult(
        contextTurns: List<ChatTurn>.unmodifiable(recentContext),
        recalledTurns: 0,
        recalledPairs: 0,
        droppedRecentTurns: 0,
      );
    }

    final indexed = <({ChatMessage message, int originalIndex})>[
      for (var i = 0; i < messages.length; i++)
        if (messages[i].id != excludedMessageId &&
            _role(messages[i].role) != null &&
            messages[i].content.trim().isNotEmpty)
          (message: messages[i], originalIndex: i),
    ]..sort((a, b) {
        final byTime = a.message.timestamp.compareTo(b.message.timestamp);
        return byTime != 0 ? byTime : a.originalIndex.compareTo(b.originalIndex);
      });

    if (indexed.length <= recentContext.length) {
      return ChronologicalRecallResult(
        contextTurns: List<ChatTurn>.unmodifiable(recentContext),
        recalledTurns: 0,
        recalledPairs: 0,
        droppedRecentTurns: 0,
      );
    }

    final recentStart = _recentStartIndex(indexed, recentContext);
    if (recentStart <= 0) {
      return ChronologicalRecallResult(
        contextTurns: List<ChatTurn>.unmodifiable(recentContext),
        recalledTurns: 0,
        recalledPairs: 0,
        droppedRecentTurns: 0,
      );
    }

    final indexById = <String, int>{
      for (var i = 0; i < indexed.length; i++) indexed[i].message.id: i,
    };

    final pairByUserId = <String, _RecallPair>{};

    for (final match in matches) {
      if (match.score < minimumScore) continue;

      final matchIndex = indexById[match.messageId];
      if (matchIndex == null || matchIndex >= recentStart) continue;

      final pair = _pairForIndex(indexed, matchIndex, recentStart);
      if (pair == null) continue;

      final existing = pairByUserId[pair.user.id];
      if (existing == null || match.score > existing.score) {
        pairByUserId[pair.user.id] = pair.copyWith(score: match.score);
      }
    }

    if (pairByUserId.isEmpty) {
      return ChronologicalRecallResult(
        contextTurns: List<ChatTurn>.unmodifiable(recentContext),
        recalledTurns: 0,
        recalledPairs: 0,
        droppedRecentTurns: 0,
      );
    }

    final ranked = pairByUserId.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final maxReplaceableTurns = math.max(0, recentContext.length - 2);
    final maxReplaceablePairs =
        math.min(maxPairs, maxReplaceableTurns ~/ 2);

    if (maxReplaceablePairs <= 0) {
      return ChronologicalRecallResult(
        contextTurns: List<ChatTurn>.unmodifiable(recentContext),
        recalledTurns: 0,
        recalledPairs: 0,
        droppedRecentTurns: 0,
      );
    }

    final selectedPairs = ranked.take(maxReplaceablePairs).toList()
      ..sort((a, b) => a.user.timestamp.compareTo(b.user.timestamp));

    final recalled = <ChatTurn>[
      for (final pair in selectedPairs) ...<ChatTurn>[
        ChatTurn(role: ChatRole.user, content: pair.user.content.trim()),
        ChatTurn(
          role: ChatRole.assistant,
          content: pair.assistant.content.trim(),
        ),
      ],
    ];

    var recentStartOffset = recalled.length;
    if (recentStartOffset >= recentContext.length) {
      recentStartOffset = recentContext.length - 2;
    }

    while (recentStartOffset < recentContext.length &&
        recentContext[recentStartOffset].role == ChatRole.assistant) {
      recentStartOffset++;
    }

    if (recentStartOffset >= recentContext.length) {
      return ChronologicalRecallResult(
        contextTurns: List<ChatTurn>.unmodifiable(recentContext),
        recalledTurns: 0,
        recalledPairs: 0,
        droppedRecentTurns: 0,
      );
    }

    final merged = <ChatTurn>[
      ...recalled,
      ...recentContext.sublist(recentStartOffset),
    ];

    return ChronologicalRecallResult(
      contextTurns: List<ChatTurn>.unmodifiable(merged),
      recalledTurns: recalled.length,
      recalledPairs: selectedPairs.length,
      droppedRecentTurns: recentStartOffset,
    );
  }

  static int _recentStartIndex(
    List<({ChatMessage message, int originalIndex})> indexed,
    List<ChatTurn> recentContext,
  ) {
    var messageIndex = indexed.length - 1;
    var recentIndex = recentContext.length - 1;

    while (messageIndex >= 0 && recentIndex >= 0) {
      final message = indexed[messageIndex].message;
      final role = _role(message.role);
      final recent = recentContext[recentIndex];

      if (role == recent.role &&
          message.content.trim() == recent.content.trim()) {
        recentIndex--;
      }

      messageIndex--;
    }

    if (recentIndex >= 0) {
      return math.max(0, indexed.length - recentContext.length);
    }

    return messageIndex + 1;
  }

  static _RecallPair? _pairForIndex(
    List<({ChatMessage message, int originalIndex})> indexed,
    int index,
    int recentStart,
  ) {
    final message = indexed[index].message;
    final role = _role(message.role);

    if (role == ChatRole.user) {
      final assistantIndex = index + 1;
      if (assistantIndex >= recentStart ||
          assistantIndex >= indexed.length ||
          _role(indexed[assistantIndex].message.role) != ChatRole.assistant) {
        return null;
      }

      return _RecallPair(
        user: message,
        assistant: indexed[assistantIndex].message,
        score: 0,
      );
    }

    if (role == ChatRole.assistant) {
      final userIndex = index - 1;
      if (userIndex < 0 ||
          index >= recentStart ||
          _role(indexed[userIndex].message.role) != ChatRole.user) {
        return null;
      }

      return _RecallPair(
        user: indexed[userIndex].message,
        assistant: message,
        score: 0,
      );
    }

    return null;
  }

  static ChatRole? _role(String role) {
    switch (role.trim().toLowerCase()) {
      case 'user':
        return ChatRole.user;
      case 'assistant':
        return ChatRole.assistant;
      default:
        return null;
    }
  }

  static bool _containsAny(String value, List<String> needles) {
    for (final needle in needles) {
      if (value.contains(needle)) return true;
    }
    return false;
  }

  static const List<String> _queryCues = <String>[
    'ti ricordi',
    'ricordi quando',
    'ricordi quale',
    'ricordi quali',
    'ricordi cosa',
    'ricordi che',
    'ricordi come',
    'avevamo deciso',
    'avevamo detto',
    'ne avevamo parlato',
    'come avevamo',
    'in precedenza avevamo',
    "l'altra volta",
    'la volta scorsa',
    'do you remember',
    'remember when',
    'we decided',
    'we agreed',
    'we said before',
    'as we decided',
    'last time',
    'tu te souviens',
    'souviens-toi',
    'on avait décidé',
    'nous avions décidé',
    'on avait dit',
    'la dernière fois',
    'te acuerdas',
    'recuerdas',
    'habíamos decidido',
    'habiamos decidido',
    'habíamos dicho',
    'habiamos dicho',
    'la otra vez',
  ];
}

class _RecallPair {
  const _RecallPair({
    required this.user,
    required this.assistant,
    required this.score,
  });

  final ChatMessage user;
  final ChatMessage assistant;
  final double score;

  _RecallPair copyWith({double? score}) => _RecallPair(
        user: user,
        assistant: assistant,
        score: score ?? this.score,
      );
}
