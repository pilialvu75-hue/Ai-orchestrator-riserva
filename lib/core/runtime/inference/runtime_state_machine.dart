enum RuntimeLifecycleState {
  uninitialized,
  loading,
  ready,
  inferencing,
  failed,
}

enum RuntimeLifecycleEvent {
  reset,
  loadRequested,
  loadCompleted,
  inferenceStarted,
  inferenceCompleted,
  inferenceFailed,
}

class RuntimeStateMachine {
  RuntimeLifecycleState _state = RuntimeLifecycleState.uninitialized;
  final List<void Function(RuntimeLifecycleState state)> _listeners =
      <void Function(RuntimeLifecycleState state)>[];

  static const Map<RuntimeLifecycleState, Set<RuntimeLifecycleEvent>>
      _allowedTransitions = <RuntimeLifecycleState, Set<RuntimeLifecycleEvent>>{
    RuntimeLifecycleState.uninitialized: <RuntimeLifecycleEvent>{
      RuntimeLifecycleEvent.reset,
      RuntimeLifecycleEvent.loadRequested,
      RuntimeLifecycleEvent.inferenceFailed,
    },
    RuntimeLifecycleState.loading: <RuntimeLifecycleEvent>{
      RuntimeLifecycleEvent.reset,
      RuntimeLifecycleEvent.loadCompleted,
      RuntimeLifecycleEvent.inferenceFailed,
    },
    RuntimeLifecycleState.ready: <RuntimeLifecycleEvent>{
      RuntimeLifecycleEvent.reset,
      RuntimeLifecycleEvent.loadRequested,
      RuntimeLifecycleEvent.inferenceStarted,
      RuntimeLifecycleEvent.inferenceFailed,
    },
    RuntimeLifecycleState.inferencing: <RuntimeLifecycleEvent>{
      RuntimeLifecycleEvent.reset,
      RuntimeLifecycleEvent.inferenceCompleted,
      RuntimeLifecycleEvent.inferenceFailed,
    },
    RuntimeLifecycleState.failed: <RuntimeLifecycleEvent>{
      RuntimeLifecycleEvent.reset,
      RuntimeLifecycleEvent.loadRequested,
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
    final nextState = _resolveNextState(_state, event);
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

  void markReady() => transition(RuntimeLifecycleEvent.loadCompleted);

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
      case RuntimeLifecycleEvent.loadCompleted:
        return RuntimeLifecycleState.ready;
      case RuntimeLifecycleEvent.inferenceStarted:
        return RuntimeLifecycleState.inferencing;
      case RuntimeLifecycleEvent.inferenceCompleted:
        return RuntimeLifecycleState.ready;
      case RuntimeLifecycleEvent.inferenceFailed:
        return RuntimeLifecycleState.failed;
    }
  }
}
