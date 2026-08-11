part of '../../runtime_core.dart';

/// Controllo ottimizzato del ciclo di polling per il runtime nativo FFI.
///
/// Il polling non deve utilizzare un numero fisso troppo basso di iterazioni
/// come proxy del timeout temporale.
///
/// In particolare, Phi-3.5 Mini può richiedere diversi secondi prima di
/// produrre il primo token. Il timeout reale del provider è già gestito da
/// AndroidFfiRuntimeProvider._firstTokenTimeout / _generationTimeout.
///
/// Il precedente limite di 1400 iterazioni poteva terminare l'inferenza dopo
/// circa 5 secondi sul dispositivo reale, molto prima del timeout temporale
/// previsto dal runtime.
///
/// Il valore attuale mantiene un hard cap di sicurezza molto più alto
/// (~45 secondi sul profilo di polling osservato), lasciando ai watchdog
/// temporali la responsabilità principale della decisione di timeout.
class _AndroidFfiRuntimePollingController {
  _AndroidFfiRuntimePollingController(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  /// Hard cap di sicurezza per evitare un loop infinito.
  ///
  /// Il vecchio valore 1400 ha causato:
  ///
  ///   1400 poll -> ~5184 ms -> poll_loop_watchdog
  ///
  /// sul dispositivo reale.
  ///
  /// Con il profilo di polling osservato (~3.7 ms/iterazione), 12000
  /// iterazioni coprono circa 44 secondi, coerentemente con il timeout
  /// release di 45 secondi del runtime.
  ///
  /// Il timeout temporale rimane comunque la protezione primaria.
  static const int _maxIdlePollIterations = 12000;

  int get maxIdlePollIterations => _maxIdlePollIterations;

  bool isIdleLimitReached(int consecutiveIdlePolls) {
    return consecutiveIdlePolls >= _maxIdlePollIterations;
  }

  static bool isImmediateRuntimeTelemetry(String message) =>
      message.startsWith('[TOKEN_STREAM]') ||
      message.startsWith('[TOKEN_LOOP]') ||
      message.startsWith('[GENERATION_STEP]') ||
      message.startsWith('[GENERATION_ALIVE]') ||
      message.startsWith('[FIRST_TOKEN_WAIT]');

  void throttledLoopLog(String message) {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (now - _owner._lastLoopLogAtMs >=
        AndroidFfiRuntimeProvider._loopLogThrottleMs) {
      _owner._lastLoopLogAtMs = now;
      _log(message);
    }
  }

  /// Incrementa il backoff in modo controllato.
  ///
  /// Parte da 0 ms per mantenere il first-token hot path reattivo e aumenta
  /// progressivamente quando il native runtime non restituisce token.
  void increaseIdleBackoff() {
    if (_owner._idleBackoffMs == 0) {
      _owner._idleBackoffMs = 4;
    } else {
      _owner._idleBackoffMs =
          (_owner._idleBackoffMs * 2).clamp(4, 32);
    }
  }

  /// Reset del backoff sul percorso di ricezione token.
  ///
  /// Garantisce che dopo l'arrivo di un token il polling successivo non
  /// introduca un ritardo artificiale.
  void resetIdleBackoff() {
    _owner._idleBackoffMs = 0;
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }
}
