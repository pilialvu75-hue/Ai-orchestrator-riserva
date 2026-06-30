import 'dart:async';
import 'package:flutter/foundation.dart';

class ChatDeadlockController {
  final Duration timeout;
  Timer? _uiDeadlockTimer;
  DateTime? _uiSendBeganAt;
  bool _uiStreamStarted = false;

  ChatDeadlockController({this.timeout = const Duration(seconds: 15)});

  bool get hasPendingSend => _uiSendBeganAt != null;
  bool get isStreamStarted => _uiStreamStarted;

  /// Registra il momento esatto in cui l'utente preme invio
  void handleSendBegan() {
    _uiSendBeganAt = DateTime.now();
    _uiStreamStarted = false;
  }

  /// Notifica il controllore che il runtime locale ha iniziato a inviare i token in streaming
  void handleStreamStarted() {
    _uiStreamStarted = true;
  }

  /// Avvia il monitoraggio in background per verificare se il runtime si è
  /// incastrato prima del primo token.
  ///
  /// I controlli di stato sono forniti come callback così ogni tick del timer
  /// legge lo stato UI/runtime più recente invece di un'istantanea obsoleta.
  /// `isSending` deve restituire se la pipeline chat è ancora in attesa di una
  /// risposta, mentre `isInferencing` deve indicare se il runtime sta già
  /// producendo token.
  void startGuard({
    required bool Function() isSending,
    required bool Function() isInferencing,
    required VoidCallback onDeadlockTriggered,
  }) {
    cancelGuard();
    _uiDeadlockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final startedAt = _uiSendBeganAt;
      if (startedAt == null || _uiStreamStarted) return;

      final elapsed = DateTime.now().difference(startedAt);
      if (isSending() && !isInferencing() && elapsed > timeout) {
        onDeadlockTriggered();
        cancelGuard();
      }
    });
  }

  void cancelGuard() {
    _uiDeadlockTimer?.cancel();
    _uiDeadlockTimer = null;
    _uiSendBeganAt = null;
    _uiStreamStarted = false;
  }

  void dispose() {
    cancelGuard();
  }
}
