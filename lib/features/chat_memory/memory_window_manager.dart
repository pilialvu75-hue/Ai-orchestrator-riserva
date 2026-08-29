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

    final userSize =
        _tokenEstimator.estimateTextSize(userPrompt);

    /*
     * Il context budget è ciò che rimane del limite totale dopo system
     * prompt e richiesta utente corrente.
     *
     * IMPORTANT:
     *
     * Non usiamo minContextSize come floor operativo.
     *
     * Se systemPrompt + userPrompt consumano già tutto il budget,
     * il contesto disponibile è semplicemente zero.
     *
     * Questo mantiene il comportamento coerente con i test esistenti
     * e, soprattutto, garantisce che il risultato non superi mai
     * maxTotalSize per effetto del fallback.
     */
    final rawBudget =
        config.maxTotalSize - systemSize - userSize;

    final availableContextBudget =
        rawBudget > 0 ? rawBudget : 0;

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

      final normalizedContent =
          _tokenEstimator.normalizeText(turn.content);

      if (normalizedContent.isEmpty) {
        trimmedLines++;
        continue;
      }

      final normalizedTurn =
          normalizedContent == turn.content
              ? turn
              : turn.copyWith(
                  content: normalizedContent,
                );

      final turnSize =
          _tokenEstimator.estimateSize(normalizedTurn);

      normalizedTurns.add(normalizedTurn);
      sizes.add(turnSize);
      runningSize += turnSize;
    }

    /*
     * Prima applichiamo il limite massimo di turni.
     *
     * Manteniamo i turni più recenti e conserviamo l'ordine originale.
     */
    var startIndex = 0;

    if (normalizedTurns.length >
        config.maxContextLines) {
      startIndex =
          normalizedTurns.length -
              config.maxContextLines;

      for (var index = 0;
          index < startIndex;
          index++) {
        runningSize -= sizes[index];
      }

      trimmedLines += startIndex;
    }

    /*
     * Seconda fase:
     *
     * riduciamo il contesto finché il suo peso rientra
     * nel budget realmente disponibile.
     *
     * I turni più vecchi vengono rimossi per primi.
     */
    var overflowDetected = false;

    while (startIndex < normalizedTurns.length) {
      final remainingLines =
          normalizedTurns.length - startIndex;

      final shouldTrimForBudget =
          runningSize > availableContextBudget;

      final shouldTrimForLineLimit =
          remainingLines > config.maxContextLines;

      if (!shouldTrimForBudget &&
          !shouldTrimForLineLimit) {
        break;
      }

      if (shouldTrimForBudget) {
        overflowDetected = true;
      }

      /*
       * Protezione numerica:
       *
       * runningSize non deve diventare negativo anche in presenza
       * di un estimator personalizzato o di dati anomali.
       */
      final sizeToRemove = sizes[startIndex];

      runningSize =
          runningSize > sizeToRemove
              ? runningSize - sizeToRemove
              : 0;

      startIndex++;
      trimmedLines++;
    }

    /*
     * Snapshot finale.
     *
     * sublist() è sicuro perché startIndex è sempre mantenuto
     * nell'intervallo [0, normalizedTurns.length].
     */
    final visibleTurns =
        startIndex == 0
            ? normalizedTurns
            : normalizedTurns.sublist(startIndex);

    /*
     * totalSize rappresenta il peso effettivamente inviato
     * al livello successivo:
     *
     *   system + user + context residuo
     *
     * Per sicurezza lo limitiamo anche qui a maxTotalSize.
     *
     * Questa protezione non modifica la selezione dei turni:
     * impedisce solamente che un estimator non lineare o un valore
     * anomalo produca un risultato contabile superiore al budget.
     */
    final calculatedTotalSize =
        runningSize + systemSize + userSize;

    final totalSize =
        calculatedTotalSize > config.maxTotalSize
            ? config.maxTotalSize
            : calculatedTotalSize;

    return MemoryWindowResult(
      contextTurns:
          List<ChatTurn>.unmodifiable(
        visibleTurns,
      ),
      trimmedLines: trimmedLines,
      overflowDetected: overflowDetected,
      totalSize: totalSize,
    );
  }
}
