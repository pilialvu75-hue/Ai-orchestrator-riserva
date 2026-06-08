import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

/// Interfaccia astratta per calcolare il peso di un turno di chat.
/// Permette di passare da un calcolo a caratteri (approssimato) a un calcolo
/// a token reali tramite FFI nativo o librerie specifiche del modello in uso.
abstract class ITokenEstimator {
  int estimateSize(ChatTurn turn);
  int estimateTextSize(String text);
}

/// Implementazione di fallback predefinita basata sui caratteri (mantiene la retrocompatibilità)
class CharacterLengthEstimator implements ITokenEstimator {
  const CharacterLengthEstimator();

  @override
  int estimateSize(ChatTurn turn) {
    return turn.content.trim().length + turn.role.name.length + 2;
  }

  @override
  int estimateTextSize(String text) {
    return text.trim().length;
  }
}
