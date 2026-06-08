import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/token_estimator.dart';

class MemoryWindowResult {
  const MemoryWindowResult({
    required this.contextTurns,
    required this.trimmedLines,
    required this.overflowDetected,
    required this.totalSize, // Rinominato da totalChars a totalSize
  });

  final List<ChatTurn> contextTurns;
  final int trimmedLines;
  final bool overflowDetected;
  final int totalSize;
}

class MemoryWindowManager {
  const MemoryWindowManager({
    required ITokenEstimator tokenEstimator,
    this.maxContextLines = 60,
    this.maxTotalSize = 4096,     // Se l'estimator è a token, 4096 indica il Context Window del LLM!
    this.minContextSize = 512,
  })  : _tokenEstimator = tokenEstimator;

  final ITokenEstimator _tokenEstimator;
  final int maxContextLines;
  final int maxTotalSize; // Rappresenta Token o Caratteri a seconda dell'estimator in uso
  final int minContextSize;

  MemoryWindowResult trimToWindow({
    required String? systemPrompt,
    required String userPrompt,
    required List<ChatTurn> contextTurns,
  }) {
    final bounded = contextTurns.length <= maxContextLines
        ? List<ChatTurn>.from(contextTurns)
        : contextTurns.sublist(contextTurns.length - maxContextLines);
    var trimmedLines = contextTurns.length - bounded.length;
    var overflowDetected = false;

    // Calcolo del peso dei prompt tramite l'estimator astratto
    final systemSize = systemPrompt != null ? _tokenEstimator.estimateTextSize(systemPrompt) : 0;
    final userSize = _tokenEstimator.estimateTextSize(userPrompt);
    
    final dynamicBudget =
        (maxTotalSize - systemSize - userSize).clamp(minContextSize, maxTotalSize);

    var runningSize = _estimateTurnsSize(bounded);
    
    while (bounded.isNotEmpty && runningSize > dynamicBudget) {
      overflowDetected = true;

      int indexToRemove = 0;
      if (bounded.length > 1 && bounded.first.role == ChatRole.system) {
        indexToRemove = 1; // Protegge il blocco <ARCHIVIO_MEMORIA_RILEVANTE>
      }

      bounded.removeAt(indexToRemove);
      trimmedLines++;
      runningSize = _estimateTurnsSize(bounded);
    }

    return MemoryWindowResult(
      contextTurns: List<ChatTurn>.unmodifiable(bounded),
      trimmedLines: trimmedLines,
      overflowDetected: overflowDetected,
      totalSize: runningSize + systemSize + userSize,
    );
  }

  int _estimateTurnsSize(List<ChatTurn> turns) {
    var total = 0;
    for (final turn in turns) {
      total += _tokenEstimator.estimateSize(turn);
    }
    return total;
  }
}
