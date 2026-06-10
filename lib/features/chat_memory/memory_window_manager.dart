import 'dart:math' as math;

import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/token_estimator.dart';

class MemoryWindowResult {
  const MemoryWindowResult({
    required this.contextTurns,
    required this.trimmedLines,
    required this.overflowDetected,
    required this.totalSize,
  });

  final List<ChatTurn> contextTurns;
  final int trimmedLines;
  final bool overflowDetected;
  final int totalSize;
}

class MemoryWindowManager {
  const MemoryWindowManager({
    required ITokenEstimator tokenEstimator,
    required MemoryWindowConfig Function() configProvider,
  })  : _tokenEstimator = tokenEstimator,
        _configProvider = configProvider;

  final ITokenEstimator _tokenEstimator;
  final MemoryWindowConfig Function() _configProvider;

  MemoryWindowResult trimToWindow({
    required String? systemPrompt,
    required String userPrompt,
    required List<ChatTurn> contextTurns,
  }) {
    final config = _configProvider();
    final systemSize = systemPrompt == null
        ? 0
        : _tokenEstimator.estimateTextSize(systemPrompt);
    final userSize = _tokenEstimator.estimateTextSize(userPrompt);
    final availableContextBudget = math.max(
      0,
      config.maxTotalSize - systemSize - userSize,
    );
    final normalizedTurns = <ChatTurn>[];
    final sizes = <int>[];
    var trimmedLines = 0;
    var runningSize = 0;

    for (final turn in contextTurns) {
      if (turn.role == ChatRole.system) {
        trimmedLines++;
        continue;
      }

      final normalizedContent = _tokenEstimator.normalizeText(turn.content);
      if (normalizedContent.isEmpty) {
        trimmedLines++;
        continue;
      }

      final normalizedTurn = normalizedContent == turn.content
          ? turn
          : turn.copyWith(content: normalizedContent);
      final turnSize = _tokenEstimator.estimateSize(normalizedTurn);

      normalizedTurns.add(normalizedTurn);
      sizes.add(turnSize);
      runningSize += turnSize;
    }

    var startIndex = 0;
    if (normalizedTurns.length > config.maxContextLines) {
      startIndex = normalizedTurns.length - config.maxContextLines;
      for (var index = 0; index < startIndex; index++) {
        runningSize -= sizes[index];
      }
      trimmedLines += startIndex;
    }

    var overflowDetected = false;
    while (startIndex < normalizedTurns.length) {
      final remainingLines = normalizedTurns.length - startIndex;
      final shouldTrimForBudget = runningSize > availableContextBudget;
      final shouldTrimForLineLimit = remainingLines > config.maxContextLines;
      if (!shouldTrimForBudget && !shouldTrimForLineLimit) {
        break;
      }

      if (shouldTrimForBudget) {
        overflowDetected = true;
      }
      runningSize -= sizes[startIndex];
      startIndex++;
      trimmedLines++;
    }

    final visibleTurns = startIndex == 0
        ? normalizedTurns
        : normalizedTurns.sublist(startIndex);

    return MemoryWindowResult(
      contextTurns: List<ChatTurn>.unmodifiable(visibleTurns),
      trimmedLines: trimmedLines,
      overflowDetected: overflowDetected,
      totalSize: runningSize + systemSize + userSize,
    );
  }
}
        
