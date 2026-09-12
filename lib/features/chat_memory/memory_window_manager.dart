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
    bool enforceEstimatedSizeBudget = true,
  }) {
    final config = _configProvider();

    final systemSize = systemPrompt == null
        ? 0
        : _tokenEstimator.estimateTextSize(systemPrompt);

    final userSize = _tokenEstimator.estimateTextSize(userPrompt);

    /*
     * Estimated-size budgeting remains available for legacy callers whose
     * runtime cannot enforce its own context capacity.
     *
     * Production conversational context now disables this heuristic before
     * routing because a character count is not a model token count. The
     * selected runtime is responsible for the final capacity bound:
     * Android llama.cpp uses the loaded GGUF tokenizer, non-Android local keeps
     * its legacy composer bound, and Cloud applies its own provider policy.
     */
    final rawBudget = config.maxTotalSize - systemSize - userSize;
    final availableContextBudget = rawBudget > 0 ? rawBudget : 0;

    final normalizedTurns = <ChatTurn>[];
    final sizes = <int>[];

    var trimmedLines = 0;
    var runningSize = 0;

    /*
     * Normalizzazione e pesatura dei turni.
     *
     * I system turn vengono esclusi dal context perché il system prompt
     * viene gestito separatamente dal runtime.
     */
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
          : turn.copyWith(
              content: normalizedContent,
            );

      final turnSize = _tokenEstimator.estimateSize(normalizedTurn);

      normalizedTurns.add(normalizedTurn);
      sizes.add(turnSize);
      runningSize += turnSize;
    }

    /*
     * Il limite di turni resta di competenza della memoria conversazionale:
     * evita history illimitate e mantiene una finestra cronologica recente.
     * Il limite di capacità del modello, invece, appartiene al runtime.
     */
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

      final shouldTrimForBudget = enforceEstimatedSizeBudget &&
          runningSize > availableContextBudget;

      final shouldTrimForLineLimit =
          remainingLines > config.maxContextLines;

      if (!shouldTrimForBudget && !shouldTrimForLineLimit) {
        break;
      }

      if (shouldTrimForBudget) {
        overflowDetected = true;
      }

      final sizeToRemove = sizes[startIndex];
      runningSize = runningSize > sizeToRemove
          ? runningSize - sizeToRemove
          : 0;

      startIndex++;
      trimmedLines++;
    }

    /*
     * Coerenza conversazionale:
     * non lasciamo una risposta assistant orfana come primo turno visibile.
     */
    while (startIndex < normalizedTurns.length &&
        normalizedTurns[startIndex].role == ChatRole.assistant) {
      final sizeToRemove = sizes[startIndex];
      runningSize = runningSize > sizeToRemove
          ? runningSize - sizeToRemove
          : 0;
      startIndex++;
      trimmedLines++;
    }

    final visibleTurns = startIndex == 0
        ? normalizedTurns
        : normalizedTurns.sublist(startIndex);

    final calculatedTotalSize = runningSize + systemSize + userSize;

    // When the heuristic budget is disabled, report the actual estimated size
    // instead of clamping the metric to a limit that was intentionally not
    // enforced. This keeps diagnostics honest while the runtime performs the
    // authoritative token-capacity check.
    final totalSize = enforceEstimatedSizeBudget &&
            calculatedTotalSize > config.maxTotalSize
        ? config.maxTotalSize
        : calculatedTotalSize;

    return MemoryWindowResult(
      contextTurns: List<ChatTurn>.unmodifiable(visibleTurns),
      trimmedLines: trimmedLines,
      overflowDetected: overflowDetected,
      totalSize: totalSize,
    );
  }
}
