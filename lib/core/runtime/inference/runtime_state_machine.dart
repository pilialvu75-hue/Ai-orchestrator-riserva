import 'package:flutter/foundation.dart';

enum RuntimeLifecycleState {
  uninitialized,
  loading,

  /// Backward-compatible alias for the first stable ready state.
  ready,

  healthy,
  verified,
  inferencing,
  failed,
}

enum RuntimeEvent {
  resetSoft,
  resetHard,
  modelDetected,
  modelCleared,
  loadRequested,
  healthObserved,
  selfTestSucceeded,
  selfTestFailed,
  runtimeUnavailableObserved,
  inferenceStarted,
  inferenceCompleted,
  errorObserved,
}

class RuntimeStateMachine {
  static int _resetCount = 0;

  RuntimeLifecycleState _state = RuntimeLifecycleState.uninitialized;
  RuntimeLifecycleState? _stateBeforeInference;
  bool _isEverReady = false;
  bool _isCurrentlyHealthy = false;
  bool _hasLoadedModel = false;
  final List<void Function(RuntimeLifecycleState state)> _listeners =
      <void Function(RuntimeLifecycleState state)>[];

  RuntimeLifecycleState get state => _state;
  bool get isEverReady => _isEverReady;
  bool get isCurrentlyHealthy => _isCurrentlyHealthy;
  bool get hasLoadedModel => _hasLoadedModel;
  bool get isReady => _isEverReady && _isCurrentlyHealthy;

  void addListener(void Function(RuntimeLifecycleState state) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(RuntimeLifecycleState state) listener) {
    _listeners.remove(listener);
  }

  RuntimeLifecycleState applyEvent(
    RuntimeEvent event, {
    String source = 'runtime',
  }) {
    final previousState = _state;
    final previousEverReady = _isEverReady;
    final previousHealthy = _isCurrentlyHealthy;
    final previousHasModel = _hasLoadedModel;
    var nextState = _state;

    switch (event) {
      case RuntimeEvent.resetSoft:
        _resetCount++;
        _stateBeforeInference = null;
        if (_isEverReady) {
          _isCurrentlyHealthy = true;
          nextState = RuntimeLifecycleState.ready;
        } else {
          _isCurrentlyHealthy = false;
          nextState = _hasLoadedModel
              ? RuntimeLifecycleState.loading
              : RuntimeLifecycleState.uninitialized;
        }
        _logReset(kind: 'soft', source: source, from: previousState);
        break;
      case RuntimeEvent.resetHard:
        _resetCount++;
        _stateBeforeInference = null;
        _isEverReady = false;
        _isCurrentlyHealthy = false;
        _hasLoadedModel = false;
        nextState = RuntimeLifecycleState.uninitialized;
        _logReset(kind: 'hard', source: source, from: previousState);
        break;
      case RuntimeEvent.modelDetected:
        _hasLoadedModel = true;
        break;
      case RuntimeEvent.modelCleared:
        _hasLoadedModel = false;
        if (!_isEverReady && _state != RuntimeLifecycleState.inferencing) {
          nextState = RuntimeLifecycleState.uninitialized;
        }
        break;
      case RuntimeEvent.loadRequested:
        nextState = RuntimeLifecycleState.loading;
        break;
      case RuntimeEvent.healthObserved:
        _isCurrentlyHealthy = true;
        if (_state != RuntimeLifecycleState.inferencing) {
          nextState = _isEverReady
              ? RuntimeLifecycleState.ready
              : RuntimeLifecycleState.healthy;
        }
        break;
      case RuntimeEvent.selfTestSucceeded:
        _isEverReady = true;
        _isCurrentlyHealthy = true;
        if (!previousEverReady) {
          debugPrint(
            '[READINESS_PROMOTION] source=$source from=${previousState.name} to=ready',
          );
        }
        if (_state != RuntimeLifecycleState.inferencing) {
          nextState = RuntimeLifecycleState.ready;
        }
        break;
      case RuntimeEvent.selfTestFailed:
        _logIgnored(
          event: event,
          source: source,
          reason: 'self_test_failures_cannot_degrade_state',
        );
        return _state;
      case RuntimeEvent.runtimeUnavailableObserved:
        if (_isEverReady) {
          _logIgnored(
            event: event,
            source: source,
            reason: 'runtime_unavailable_forbidden_after_ready',
          );
          return _state;
        }
        break;
      case RuntimeEvent.inferenceStarted:
        if (!_hasLoadedModel) {
          _logIgnored(
            event: event,
            source: source,
            reason: 'no_model_loaded',
          );
          return _state;
        }
        _stateBeforeInference = _state;
        nextState = RuntimeLifecycleState.inferencing;
        break;
      case RuntimeEvent.inferenceCompleted:
        if (_state != RuntimeLifecycleState.inferencing) {
          _logIgnored(
            event: event,
            source: source,
            reason: 'not_currently_inferencing',
          );
          return _state;
        }
        nextState = _stateBeforeInference ??
            (_isEverReady
                ? RuntimeLifecycleState.ready
                : (_hasLoadedModel
                    ? RuntimeLifecycleState.healthy
                    : RuntimeLifecycleState.uninitialized));
        _stateBeforeInference = null;
        break;
      case RuntimeEvent.errorObserved:
        if (_state == RuntimeLifecycleState.inferencing) {
          nextState = _stateBeforeInference ??
              (_isEverReady
                  ? RuntimeLifecycleState.ready
                  : (_hasLoadedModel
                      ? RuntimeLifecycleState.healthy
                      : RuntimeLifecycleState.uninitialized));
          _stateBeforeInference = null;
          break;
        }
        _stateBeforeInference = null;
        if (_isEverReady) {
          nextState = RuntimeLifecycleState.ready;
        } else {
          _isCurrentlyHealthy = false;
          nextState = RuntimeLifecycleState.failed;
        }
        break;
    }

    final changed = nextState != previousState ||
        previousEverReady != _isEverReady ||
        previousHealthy != _isCurrentlyHealthy ||
        previousHasModel != _hasLoadedModel;
    _state = nextState;

    if (changed) {
      debugPrint(
        '[RUNTIME_EVENT] event=${event.name} source=$source '
        'from=${previousState.name} to=${_state.name} '
        'ever_ready=$_isEverReady healthy=$_isCurrentlyHealthy has_model=$_hasLoadedModel',
      );
      for (final listener in List<void Function(RuntimeLifecycleState state)>.of(
        _listeners,
      )) {
        listener(_state);
      }
    }

    return _state;
  }

  void reset() => resetHard();

  void resetSoft() =>
      applyEvent(RuntimeEvent.resetSoft, source: 'RuntimeStateMachine.resetSoft');

  void resetHard() =>
      applyEvent(RuntimeEvent.resetHard, source: 'RuntimeStateMachine.resetHard');

  void markModelDetected() => applyEvent(
        RuntimeEvent.modelDetected,
        source: 'RuntimeStateMachine.markModelDetected',
      );

  void markModelCleared() => applyEvent(
        RuntimeEvent.modelCleared,
        source: 'RuntimeStateMachine.markModelCleared',
      );

  void markLoading() => applyEvent(
        RuntimeEvent.loadRequested,
        source: 'RuntimeStateMachine.markLoading',
      );

  void markHealthy() => applyEvent(
        RuntimeEvent.healthObserved,
        source: 'RuntimeStateMachine.markHealthy',
      );

  void markReady() => applyEvent(
        RuntimeEvent.selfTestSucceeded,
        source: 'RuntimeStateMachine.markReady',
      );

  void markVerified() => applyEvent(
        RuntimeEvent.selfTestSucceeded,
        source: 'RuntimeStateMachine.markVerified',
      );

  void markRuntimeUnavailable() => applyEvent(
        RuntimeEvent.runtimeUnavailableObserved,
        source: 'RuntimeStateMachine.markRuntimeUnavailable',
      );

  void markInferencing() => applyEvent(
        RuntimeEvent.inferenceStarted,
        source: 'RuntimeStateMachine.markInferencing',
      );

  void markInferenceCompleted() => applyEvent(
        RuntimeEvent.inferenceCompleted,
        source: 'RuntimeStateMachine.markInferenceCompleted',
      );

  void markFailed() => applyEvent(
        RuntimeEvent.errorObserved,
        source: 'RuntimeStateMachine.markFailed',
      );

  void _logReset({
    required String kind,
    required String source,
    required RuntimeLifecycleState from,
  }) {
    debugPrint(
      '[STATE_RESET] kind=$kind source=$source from=${from.name} reset_count=$_resetCount',
    );
  }

  void _logIgnored({
    required RuntimeEvent event,
    required String source,
    required String reason,
  }) {
    debugPrint(
      '[RUNTIME_EVENT_IGNORED] event=${event.name} source=$source reason=$reason '
      'state=${_state.name} ever_ready=$_isEverReady healthy=$_isCurrentlyHealthy has_model=$_hasLoadedModel',
    );
  }
}
