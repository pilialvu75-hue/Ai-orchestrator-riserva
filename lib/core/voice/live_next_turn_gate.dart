import 'dart:async';

/// Live does not start another microphone turn until the user explicitly taps.
///
/// Safety fallback while acoustic echo cancellation and speaker attribution
/// are not verified on each device. The initial turn may begin automatically;
/// every subsequent turn must cross this gate.
final class LiveNextTurnGate {
  Completer<void>? _pending;
  bool _closed = false;

  bool get isWaiting => _pending != null && !_pending!.isCompleted;

  Future<void> waitForUser() {
    if (_closed) return Future<void>.value();
    final existing = _pending;
    if (existing != null) return existing.future;
    final pending = Completer<void>();
    _pending = pending;
    return pending.future;
  }

  bool requestNextTurn() {
    if (_closed) return false;
    final pending = _pending;
    if (pending == null || pending.isCompleted) return false;
    _pending = null;
    pending.complete();
    return true;
  }

  /// Prevent abandoned futures when the overlay closes or is disposed.
  void close() {
    if (_closed) return;
    _closed = true;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }
}
