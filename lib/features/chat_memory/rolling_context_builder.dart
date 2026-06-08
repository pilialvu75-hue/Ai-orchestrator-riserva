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
    // Set isolato solo per evitare duplicati interni alla memoria semantica (RAG)
    final semanticSeen = <String>{};
    final turns = <ChatTurn>[];

    // 1. Elaborazione e Isolamento della Memoria Semantica (RAG)
    final bufferRAG = StringBuffer();
    for (final recalled in recalledContext) {
      final normalized = _normalizer.normalize(recalled);
      if (normalized.content.isEmpty) continue;
      
      final key = _turnKey(normalized);
      if (!semanticSeen.add(key)) continue;

      // Costruiamo un blocco testuale strutturato e neutrale per l'archivio storico
      final prefix = normalized.role == ChatRole.assistant ? 'AI' : 'UTENTE';
      bufferRAG.writeln('[$prefix]: ${normalized.content}');
    }

    // Se ci sono ricordi semantici, li iniettiamo come un singolo blocco di sistema contestuale
    // Questo evita l'anacronismo cronologico ed è compatibile con qualsiasi backend (Locale FFI o Cloud)
    if (bufferRAG.isNotEmpty) {
      turns.add(
        ChatTurn(
          role: ChatRole.system,
          content: '<ARCHIVIO_MEMORIA_RILEVANTE>\n${bufferRAG.toString().trim()}\n</ARCHIVIO_MEMORIA_RILEVANTE>',
        ),
      );
    }

    // 2. Iniezione dell'Integrità Cronologica (La verità della Chat corrente)
    // Rimosso il set 'seen' globale per impedire la cancellazione dei messaggi multi-turno identici
    for (final message in messages) {
      if (excludedMessageId != null && message.id == excludedMessageId) continue;

      final turn = _normalizer.normalize(
        ChatTurn(
          role: ChatTurnNormalizer.roleFromText(message.role),
          content: message.content,
        ),
      );
      if (turn.content.isEmpty) continue;
      
      turns.add(turn);
    }

    // 3. Calcolo dinamico della finestra di contesto tramite il Manager
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

  String _turnKey(ChatTurn turn) =>
      '${turn.role.name}:${turn.content.trim().toLowerCase()}';
}
