part of 'runtime_core.dart';

class _AndroidFfiConcurrencyManager {
  _AndroidFfiConcurrencyManager(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  Future<void> runInferenceSerially(Future<void> Function() action) {
    _log(
      '[AI_RUNTIME_MONITOR] FORENSIC - File: inference_concurrency_manager.part.dart | Function: runInferenceSerially() | BEFORE entry',
    );
    final previousTail = _owner._inferenceTail ?? Future<void>.value();
    _log('[SERIAL_QUEUE_SCHEDULE] tail_hash=${previousTail.hashCode} schedule_ts=${DateTime.now().microsecondsSinceEpoch} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}');
    _owner._inferenceTail = previousTail
        .catchError((e, st) {
          _log(
            'Inference queue upstream error swallowed safely to protect pipeline continuity: $e\n$st',
          );
        })
        .then((_) async {
          try {
            _log('[SERIAL_QUEUE_DEQUEUE] dequeue_ts=${DateTime.now().microsecondsSinceEpoch} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}');
            _log(
            '[AI_RUNTIME_MONITOR] FORENSIC - File: inference_concurrency_manager.part.dart | Function: runInferenceSerially() | BEFORE action()',
            );
            await action();
            _log(
            '[AI_RUNTIME_MONITOR] FORENSIC - File: inference_concurrency_manager.part.dart | Function: runInferenceSerially() | AFTER action()',
            );
          } catch (e, st) {
            _log(
              'Inference task failed safely within protected serial queue execution: $e\n$st',
            );
          }
        });
    _log(
      '[AI_RUNTIME_MONITOR] FORENSIC - File: inference_concurrency_manager.part.dart | Function: runInferenceSerially() | AFTER exit',
    );
    return _owner._inferenceTail!;
  }

  bool claimInferenceSlot(String sessionId) {
    if (_owner._activeInferenceSessions.contains(sessionId)) return false;
    _owner._activeInferenceSessions.add(sessionId);
    return true;
  }

  void releaseInferenceSlot(String sessionId) {
    _owner._activeInferenceSessions.remove(sessionId);
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }
}
