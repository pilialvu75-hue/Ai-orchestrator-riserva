part of '../../runtime_core.dart';

/// Layer Forense e di Deidratazione: distrugge il grafo degli oggetti complessi
/// estraendo solo primitive serializzabili e analizzando la natura del tipo
/// per prevenire leak di contesto (Zone, Timer) attraverso i boundary asincroni.
String _dehydrateAndTraceError(Object e, StackTrace? st) {
  final buffer = StringBuffer();
  
  final String errorType = '${e.runtimeType}';
  final int errorHash = identityHashCode(e);
  final String stackType = st != null ? '${st.runtimeType}' : 'N/A';
  
  buffer.write('[FORENSIC_TYPE] $errorType | [HASH] $errorHash | [STACK_TYPE] $stackType\n');
  buffer.write('[DEHYDRATED_MSG] $e');
  
  if (st != null) {
    buffer.write('\n[SAFE_STACK_TRACE]\n$st');
  }
  
  // Stampa nativa immediata per bypassare qualsiasi layer reattivo o asincrono dell'applicazione
  stderr.writeln('[AI_ORCHESTRATOR_TELEMETRY] Eccezione intercettata nel modulo concorrenza. Tipo: $errorType, Hash: $errorHash');
  
  return buffer.toString();
}

class _AndroidFfiConcurrencyManager {
  _AndroidFfiConcurrencyManager(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  Future<void> runInferenceSerially(Future<void> Function() action) {
    _log(
      '[AI_RUNTIME_MONITOR] FORENSIC - File: inference_concurrency_manager.part.dart | Function: runInferenceSerially() | BEFORE entry',
    );
    final previousTail = _owner._inferenceTail ?? Future<void>.value();
    _log('[SERIAL_QUEUE_SCHEDULE] tail_hash=${previousTail.hashCode} schedule_ts=${DateTime.now().microsecondsSinceEpoch} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}');
    
    final task = runSerialInferenceTask(previousTail, action);
    // Recover only the queue tail, not the result returned to this request.
    // streamInference must receive failures so its terminal sink can close.
    _owner._inferenceTail = task.catchError((Object error, StackTrace stack) {
      _log(_dehydrateAndTraceError(error, stack));
    });
    return task;
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
