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
    
    // 1. Calcolo rigoroso dello spazio occupato dai prompt statici
    final systemSize = systemPrompt == null
        ? 0
        : _tokenEstimator.estimateTextSize(systemPrompt);
    final userSize = _tokenEstimator.estimateTextSize(userPrompt);

    // 2. Determinazione del budget reale disponibile per la cronologia dei turni
    final allowedContextSize = config.maxTotalSize - systemSize - userSize;
    
    // Se è configurato un minContextSize ed il budget reale è inferiore, 
    // lo proteggiamo per garantire la soglia minima di operatività dell'AI.
    final effectiveBudget = config.minContextSize != null && allowedContextSize < config.minContextSize!
        ? config.minContextSize!
        : allowedContextSize;

    final normalizedTurns = <ChatTurn>[];
    final sizes = <int>[];
    var trimmedLines = 0;
    var runningSize = 0;

    // 3. Filtro e normalizzazione iniziale dei turni (esclusione Turni di Sistema interni)
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
    var overflowDetected = false;

    // 4. Unico ciclo di sbarramento: rimuove dal turno più vecchio (startIndex) 
    // finché non vengono rispettati contemporaneamente sia il limite di linee che il budget di token.
    while (startIndex < normalizedTurns.length) {
      final remainingLines = normalizedTurns.length - startIndex;
      final budgetViolated = runningSize > effectiveBudget;
      final linesViolated = remainingLines > config.maxContextLines;

      if (!budgetViolated && !linesViolated) {
        break; // Entrambi i vincoli sono soddisfatti, usciamo.
      }

      if (budgetViolated) {
        overflowDetected = true; // L'overflow viene tracciato solo se causato dal superamento dei token
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
