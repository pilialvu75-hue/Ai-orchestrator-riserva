part of '../../runtime_core.dart';

/// Controllo ottimizzato del ciclo di polling per il runtime nativo FFI.
///
/// Il polling non deve utilizzare un numero fisso di iterazioni come proxy
/// del tempo trascorso. Il numero di poll eseguiti dipende dal dispositivo,
/// dal carico e soprattutto dal fatto che il percorso pre-first-token usa
/// `Duration.zero` per cedere il controllo senza introdurre un ritardo fisso.
///
/// I watchdog temporali del provider sono quindi l'unica autorita' terminale:
/// - first-token deadline / generation timeout prima del primo token;
/// - no-token-progress timeout dopo l'avvio dello streaming.
///
/// La vecchia soglia a iterazioni viene mantenuta esclusivamente come
/// telemetria diagnostica: raggiungerla non deve piu' cancellare una
/// generazione ancora legittimamente in prefill/computazione.
class _AndroidFfiRuntimePollingController {
  _AndroidFfiRuntimePollingController(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  /// Soglia diagnostica storica.
  ///
  /// In passato 1400 poll potevano terminare l'inferenza in circa 5 secondi.
  /// Il successivo valore 12000 era stato scelto assumendo ~3.7 ms/poll, ma
  /// quell'assunzione non e' valida sul percorso pre-first-token, che effettua
  /// yield a `Duration.zero` e puo' quindi consumare 12000 iterazioni molto
  /// prima del vero first-token deadline.
  static const int _maxIdlePollIterations = 12000;

  int get maxIdlePollIterations => _maxIdlePollIterations;

  /// Compatibilita' temporanea con il call-site storico.
  ///
  /// Non restituisce mai `true`: una quantita' di iterazioni non e' un clock e
  /// non puo' avere autorita' terminale. Al raggiungimento esatto della vecchia
  /// soglia emette una sola evidenza diagnostica per quel tratto di inattivita'.
  bool isIdleLimitReached(int consecutiveIdlePolls) {
    if (consecutiveIdlePolls == _maxIdlePollIterations) {
      _log(
        '[POLL_IDLE_DIAGNOSTIC] idle_polls=$consecutiveIdlePolls '
        'terminal_authority=time_based_watchdogs',
      );
    }
    return false;
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
