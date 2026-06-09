import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

/// Interfaccia astratta per calcolare il peso di un turno di chat.
/// Permette di passare da un calcolo a caratteri (approssimato) a un calcolo
/// a token reali tramite FFI nativo o librerie specifiche del modello in uso.
abstract class ITokenEstimator {
  static const int _space = 32;
  static const int _tab = 9;
  static const int _newline = 10;
  static const int _carriageReturn = 13;

  int estimateSize(ChatTurn turn);
  int estimateTextSize(String text);

  int estimateTextSizeBatch(Iterable<String> texts) {
    var total = 0;
    for (final text in texts) {
      total += estimateTextSize(text);
    }
    return total;
  }

  int estimateAvailableContextSize({
    required int maxTotalSize,
    required int systemSize,
    required int userSize,
    required int minContextSize,
  }) {
    final available = maxTotalSize - systemSize - userSize;
    if (available < minContextSize) {
      return minContextSize;
    }
    if (available > maxTotalSize) {
      return maxTotalSize;
    }
    return available;
  }

  String normalizeText(String text) {
    if (text.isEmpty) return text;

    final startCode = text.codeUnitAt(0);
    final endCode = text.codeUnitAt(text.length - 1);
    if (!_isTrimBoundary(startCode) && !_isTrimBoundary(endCode)) {
      return text;
    }

    var start = 0;
    var end = text.length;
    while (start < end && _isTrimBoundary(text.codeUnitAt(start))) {
      start++;
    }
    while (end > start && _isTrimBoundary(text.codeUnitAt(end - 1))) {
      end--;
    }
    if (start == 0 && end == text.length) {
      return text;
    }
    if (start >= end) {
      return '';
    }
    return text.substring(start, end);
  }

  bool _isTrimBoundary(int codeUnit) {
    return codeUnit == _space ||
        codeUnit == _tab ||
        codeUnit == _newline ||
        codeUnit == _carriageReturn;
  }
}

/// Implementazione di fallback predefinita basata sui caratteri (mantiene la retrocompatibilità)
class CharacterLengthEstimator implements ITokenEstimator {
  const CharacterLengthEstimator();

  @override
  int estimateSize(ChatTurn turn) {
    return estimateTextSize(turn.content) + turn.role.name.length + 2;
  }

  @override
  int estimateTextSize(String text) {
    final normalized = normalizeText(text);
    return normalized.length;
  }
}
