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
    
    // NO OBJECT LEAK RULE: Ogni frammento della catena viene forzato a risolversi in un valore neutro.
    // Viene implementata la Fault Isolation completa salvaguardando la coda globale.
    _owner._inferenceTail = previousTail
        .catchError((e, st) {
          final trace = _dehydrateAndTraceError(e, st);
          _log(
            'Inference queue upstream error swallowed safely to protect pipeline continuity (DEHYDRATED):\n$trace',
          );
          return Future<void>.value(); // Silenziamento completo: la catena globale si rigenera qui pulita
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
            final trace = _dehydrateAndTraceError(e, st);
            _log(
              'Inference task failed safely within protected serial queue execution (DEHYDRATED):\n$trace',
            );
            // Nessun rethrow per impedire la contaminazione distruttiva del downstream
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
