/// Polling control for the Android FFI runtime token loop.
///
/// Owns idle backoff and loop telemetry helpers while preserving the original
/// polling limits and timing behavior.
part of runtime_core;

class _AndroidFfiRuntimePollingController {
  _AndroidFfiRuntimePollingController(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  static const int _maxIdlePollIterations = 2400;

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

  void increaseIdleBackoff() {
    _owner._idleBackoffMs = (_owner._idleBackoffMs * 2).clamp(24, 200);
  }

  void resetIdleBackoff() {
    _owner._idleBackoffMs = 24;
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }
}
