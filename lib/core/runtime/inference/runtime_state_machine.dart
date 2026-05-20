enum RuntimeLifecycleState {
  uninitialized,
  loading,
  healthy,
  verified,
  inferencing,
  failed,
}

enum RuntimeLifecycleEvent {
  reset,
  loadRequested,
  healthObserved,
  verificationConfirmed,
  inferenceStarted,
  inferenceCompleted,
  inferenceFailed,
}

class RuntimeStateMachine {
  RuntimeLifecycleState _state = RuntimeLifecycleState.uninitialized;
  RuntimeLifecycleState? _stateBeforeInference;
  final List<void Function(RuntimeLifecycleState state)> _listeners =
      <void Function(RuntimeLifecycleState state)>[];

  static const Map<RuntimeLifecycleState, Set<RuntimeLifecycleEvent>>
      _allowedTransitions = <RuntimeLifecycleState, Set<RuntimeLifecycleEvent>>{
    RuntimeLifecycleState.uninitialized: <RuntimeLifecycleEvent>{
      RuntimeLifecycleEvent.reset,
      RuntimeLifecycleEvent.loadRequested,
      RuntimeLifecycleEvent.healthObserved,
      RuntimeLifecycleEvent.verificationConfirmed,
      RuntimeLifecycleEvent.inferenceFailed,
    },
    RuntimeLifecycleState.loading: <RuntimeLifecycleEvent>{
      RuntimeLifecycleEvent.reset,
      RuntimeLifecycleEvent.healthObserved,
      RuntimeLifecycleEvent.verificationConfirmed,
      RuntimeLifecycleEvent.inferenceFailed,
    },
    RuntimeLifecycleState.healthy: <RuntimeLifecycleEvent>{
      RuntimeLifecycleEvent.reset,
      RuntimeLifecycleEvent.loadRequested,
      RuntimeLifecycleEvent.verificationConfirmed,
      RuntimeLifecycleEvent.inferenceStarted,
      RuntimeLifecycleEvent.inferenceFailed,
    },
    RuntimeLifecycleState.verified: <RuntimeLifecycleEvent>{
      RuntimeLifecycleEvent.reset,
      RuntimeLifecycleEvent.loadRequested,
      RuntimeLifecycleEvent.inferenceStarted,
      RuntimeLifecycleEvent.inferenceFailed,
    },
    RuntimeLifecycleState.inferencing: <RuntimeLifecycleEvent>{
      RuntimeLifecycleEvent.reset,
      RuntimeLifecycleEvent.inferenceCompleted,
      // First token can confirm runtime viability while inference is active.
      RuntimeLifecycleEvent.verificationConfirmed,
      RuntimeLifecycleEvent.inferenceFailed,
    },
    RuntimeLifecycleState.failed: <RuntimeLifecycleEvent>{
      RuntimeLifecycleEvent.reset,
      RuntimeLifecycleEvent.loadRequested,
      RuntimeLifecycleEvent.healthObserved,
      RuntimeLifecycleEvent.verificationConfirmed,
      RuntimeLifecycleEvent.inferenceFailed,
    },
  };

  RuntimeLifecycleState get state => _state;

  Map<RuntimeLifecycleState, Set<RuntimeLifecycleEvent>> get transitionMap =>
      _allowedTransitions;

  void addListener(void Function(RuntimeLifecycleState state) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(RuntimeLifecycleState state) listener) {
    _listeners.remove(listener);
  }

  RuntimeLifecycleState transition(RuntimeLifecycleEvent event) {
    final allowed = _allowedTransitions[_state];
    if (allowed != null && !allowed.contains(event)) return _state;
    if (event == RuntimeLifecycleEvent.inferenceStarted) {
      _stateBeforeInference = _state;
    }
    RuntimeLifecycleState nextState;
    if (event == RuntimeLifecycleEvent.inferenceCompleted &&
        _state == RuntimeLifecycleState.inferencing) {
      nextState = _stateBeforeInference ?? RuntimeLifecycleState.healthy;
      _stateBeforeInference = null;
    } else {
      nextState = _resolveNextState(_state, event);
      if (event == RuntimeLifecycleEvent.reset ||
          event == RuntimeLifecycleEvent.inferenceFailed) {
        _stateBeforeInference = null;
      }
    }
    if (nextState == _state) return _state;
    _state = nextState;
    for (final listener in List<void Function(RuntimeLifecycleState state)>.of(
      _listeners,
    )) {
      listener(_state);
    }
    return _state;
  }

  void reset() => transition(RuntimeLifecycleEvent.reset);

  void markLoading() => transition(RuntimeLifecycleEvent.loadRequested);

  void markHealthy() => transition(RuntimeLifecycleEvent.healthObserved);

  void markVerified() => transition(RuntimeLifecycleEvent.verificationConfirmed);

  void markInferencing() => transition(RuntimeLifecycleEvent.inferenceStarted);

  void markInferenceCompleted() =>
      transition(RuntimeLifecycleEvent.inferenceCompleted);

  void markFailed() => transition(RuntimeLifecycleEvent.inferenceFailed);

  static RuntimeLifecycleState _resolveNextState(
    RuntimeLifecycleState currentState,
    RuntimeLifecycleEvent event,
  ) {
    switch (event) {
      case RuntimeLifecycleEvent.reset:
        return RuntimeLifecycleState.uninitialized;
      case RuntimeLifecycleEvent.loadRequested:
        return RuntimeLifecycleState.loading;
      case RuntimeLifecycleEvent.healthObserved:
        return RuntimeLifecycleState.healthy;
      case RuntimeLifecycleEvent.verificationConfirmed:
        return RuntimeLifecycleState.verified;
      case RuntimeLifecycleEvent.inferenceStarted:
        return RuntimeLifecycleState.inferencing;
      case RuntimeLifecycleEvent.inferenceCompleted:
        return RuntimeLifecycleState.verified;
      case RuntimeLifecycleEvent.inferenceFailed:
        return RuntimeLifecycleState.failed;
    }
  }
}
