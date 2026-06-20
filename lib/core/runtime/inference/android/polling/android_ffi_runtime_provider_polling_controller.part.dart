part of '../../runtime_core.dart';

/// Controllo ottimizzato del ciclo di polling per il runtime nativo FFI.
///
/// Abbassa la latenza iniziale a zero per massimizzare il throughput dei modelli
/// locali leggeri (Phi-3.5) e riallinea le iterazioni massime al watchdog di Dart.
class _AndroidFfiRuntimePollingController {
  _AndroidFfiRuntimePollingController(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  // Ricalcolato sul watchdog di Dart: 35 secondi di timeout / 25ms medi = ~1400 iterazioni.
  // Evita che il ciclo nativo ignori il timeout imposto dal provider superiore.
  static const int _maxIdlePollIterations = 1400;

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
    if (now - _owner._lastLoopLogAtMs >= AndroidFfiRuntimeProvider._loopLogThrottleMs) {
      _owner._lastLoopLogAtMs = now;
      _log(message);
    }
  }

  /// Incrementa il backoff in modo controllato.
  /// Parte da 0ms (yield immediato dell'event loop) e sale fino a un tetto
  /// compatibile con la reattività dell'interfaccia utente (32ms).
  void increaseIdleBackoff() {
    if (_owner._idleBackoffMs == 0) {
      _owner._idleBackoffMs = 4; // Primo gradino dopo lo yield a zero
    } else {
      _owner._idleBackoffMs = (_owner._idleBackoffMs * 2).clamp(4, 32);
    }
  }

  /// Reset del backoff a zero per l'hot-path di ricezione token.
  /// Garantisce che non appena viene emesso un token, il campionamento successivo
  /// avvenga senza alcun ritardo artificiale.
  void resetIdleBackoff() {
    _owner._idleBackoffMs = 0; // 0ms indica un Duration.zero (microtask yield)
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }
}
