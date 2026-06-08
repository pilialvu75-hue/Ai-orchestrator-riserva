import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

class MemoryWindowResult {
  const MemoryWindowResult({
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

class MemoryWindowManager {
  /// Il costruttore ora accetta parametri configurabili dinamicamente a runtime
  /// a seconda della piattaforma (Android, MacOS, Windows, Linux) e del modello (1B, 7B, 8B, Cloud).
  const MemoryWindowManager({
    this.maxContextLines = 60,       // Aumentato per accogliere dialoghi multi-turno complessi
    this.maxTotalChars = 16000,      // Ampio margine adattativo di base (~4000 token), sovrascrivibile
    this.minContextChars = 1024,     // Pavimento minimo protetto per evitare frammentazioni selvagge
  });

  final int maxContextLines;
  final int maxTotalChars;
  final int minContextChars;

  MemoryWindowResult trimToWindow({
    required String? systemPrompt,
    required String userPrompt,
    required List<ChatTurn> contextTurns,
  }) {
    // 1. Limitazione iniziale basata sul numero massimo di linee ammesse
    final bounded = contextTurns.length <= maxContextLines
        ? List<ChatTurn>.from(contextTurns)
        : contextTurns.sublist(contextTurns.length - maxContextLines);
    var trimmedLines = contextTurns.length - bounded.length;
    var overflowDetected = false;

    final systemChars = systemPrompt?.trim().length ?? 0;
    final userChars = userPrompt.trim().length;
    
    // Calcolo del budget dinamico per la cronologia volatile
    final dynamicBudget =
        (maxTotalChars - systemChars - userChars).clamp(minContextChars, maxTotalChars);

    var runningChars = _estimateChars(bounded);
    
    // 2. Strategia di Clipping Selettivo Anti-Frammentazione
    // Se sforiamo il budget di caratteri, dobbiamo liberare spazio senza distruggere i tag critici.
    while (bounded.isNotEmpty && runningChars > dynamicBudget) {
      overflowDetected = true;

      // Cerchiamo il primo indice sacrificabile (Messaggi cronologici della chat)
      // L'indice 0 potrebbe contenere il blocco di sistema <ARCHIVIO_MEMORIA_RILEVANTE>
      // inserito dal RollingContextBuilder. Dobbiamo proteggerlo se possibile.
      int indexToRemove = 0;
      
      if (bounded.length > 1 && bounded.first.role == ChatRole.system) {
        // Se il primo elemento è il blocco RAG di sistema, sacrifichiamo il messaggio successivo (la chat vecchia)
        indexToRemove = 1;
      }

      bounded.removeAt(indexToRemove);
      trimmedLines++;
      runningChars = _estimateChars(bounded);
    }

    return MemoryWindowResult(
      contextTurns: List<ChatTurn>.unmodifiable(bounded),
      trimmedLines: trimmedLines,
      overflowDetected: overflowDetected,
      totalChars: runningChars + systemChars + userChars,
    );
  }

  int _estimateChars(List<ChatTurn> turns) {
    var chars = 0;
    for (final turn in turns) {
      chars += turn.content.trim().length + turn.role.name.length + 2;
    }
    return chars;
  }
}
