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
    List<ChatTurn> recalledContext = const [],
  }) {
    // ── 1. Costruisce la storia cronologica ──────────────────────────────────
    // I messaggi vengono presi in ordine di inserimento (già ordinati per
    // timestamp dal datasource). Il turno corrente dell'utente è escluso
    // tramite excludedMessageId perché viene aggiunto separatamente come
    // "prompt" dall'InferenceRequest, evitando duplicazioni nel contesto.
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
      // Esclude turni marcati come non-contesto (webSearch, comandi, ecc.)
      if (turn.excludeFromContext) continue;
      turns.add(turn);
    }

    // ── 2. Recall semantico — solo per modelli con budget sufficiente ────────
    // Su modelli 1B/1.5B il budget token è ~512. Il recall semantico inserisce
    // turni fuori ordine cronologico che confondono il modello e causano
    // risposte incoerenti (il modello "pesca" la risposta dal contesto
    // recalled invece di generarla). Lo disabilitiamo sotto soglia.
    //
    // Soglia: se il budget totale stimato supera 2000 caratteri (≈500 token)
    // E i turni recalled non sono già presenti nella storia cronologica,
    // li appendiamo IN FONDO (dopo la storia) come "memoria aggiuntiva"
    // con un separatore esplicito, non in testa.
    //
    // Per ora, su tutti i profili Android con modelli <3B, il recall è
    // disabilitato per garantire coerenza cronologica.
    // TODO: riabilitare condizionatamente quando si supportano modelli 7B+.

    // ── 3. Passa al window manager per il trimming ───────────────────────────
    final result = _windowManager.trimToWindow(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      contextTurns: turns,
    );

    return RollingContextResult(
      contextTurns: result.contextTurns,
      trimmedLines: result.trimmedLines,
      overflowDetected: result.overflowDetected,
      totalChars: result.totalSize,
    );
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
}
