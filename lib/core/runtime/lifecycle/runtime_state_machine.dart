import 'dart:async';

import 'package:flutter/foundation.dart';

/// All possible states the AI runtime can occupy during its lifecycle.
enum RuntimeLifecycleState {
  uninitialized,
  loadingModel,
  validatingModel,
  initializingRuntime,
  initializingTokenizer,
  initializingEmbeddings,
  allocatingContext,
  warmingUp,
  runningHealthcheck,
  ready,
  inferencing,
  recovering,
  failed,
}

/// Deterministic finite-state machine that governs the runtime lifecycle.
///
/// Only the transitions declared in [_allowedTransitions] are valid.
/// Attempts to move to an undeclared next-state are rejected (returning
/// `false`) and logged with the `[RUNTIME_STATE]` prefix so they surface
/// clearly in debug output and crash reporters.
class RuntimeStateMachine {
  RuntimeStateMachine() : _currentState = RuntimeLifecycleState.uninitialized;

  RuntimeLifecycleState _currentState;

  final StreamController<RuntimeLifecycleState> _controller =
      StreamController<RuntimeLifecycleState>.broadcast();

  /// Emits every state change, including those triggered by [forceState].
  Stream<RuntimeLifecycleState> get stateStream => _controller.stream;

  /// The state the machine currently occupies.
  RuntimeLifecycleState get currentState => _currentState;

  // ---------------------------------------------------------------------------
  // Convenience getters
  // ---------------------------------------------------------------------------

  bool get isReady => _currentState == RuntimeLifecycleState.ready;

  bool get isInferencing =>
      _currentState == RuntimeLifecycleState.inferencing;

  bool get isFailed => _currentState == RuntimeLifecycleState.failed;

  /// True only when the runtime is idle and ready to accept an inference
  /// request.  Use this guard before starting any generation.
  bool get canStartInference =>
      _currentState == RuntimeLifecycleState.ready;

  // ---------------------------------------------------------------------------
  // Allowed-transition table
  // ---------------------------------------------------------------------------

  /// Exhaustive map of permitted forward-and-backward transitions.
  ///
  /// The recovery loop (`recovering → uninitialized`) is intentionally
  /// separate from the happy-path sequence so that failure modes are easy to
  /// audit at a glance.
  static const Map<RuntimeLifecycleState, Set<RuntimeLifecycleState>>
      _allowedTransitions = {
    RuntimeLifecycleState.uninitialized: {
      RuntimeLifecycleState.loadingModel,
      RuntimeLifecycleState.recovering,
    },
    RuntimeLifecycleState.loadingModel: {
      RuntimeLifecycleState.validatingModel,
      RuntimeLifecycleState.failed,
    },
    RuntimeLifecycleState.validatingModel: {
      RuntimeLifecycleState.initializingRuntime,
      RuntimeLifecycleState.failed,
    },
    RuntimeLifecycleState.initializingRuntime: {
      RuntimeLifecycleState.initializingTokenizer,
      RuntimeLifecycleState.failed,
    },
    RuntimeLifecycleState.initializingTokenizer: {
      RuntimeLifecycleState.initializingEmbeddings,
      RuntimeLifecycleState.failed,
    },
    RuntimeLifecycleState.initializingEmbeddings: {
      RuntimeLifecycleState.allocatingContext,
      RuntimeLifecycleState.failed,
    },
    RuntimeLifecycleState.allocatingContext: {
      RuntimeLifecycleState.warmingUp,
      RuntimeLifecycleState.failed,
    },
    RuntimeLifecycleState.warmingUp: {
      RuntimeLifecycleState.runningHealthcheck,
      RuntimeLifecycleState.failed,
    },
    RuntimeLifecycleState.runningHealthcheck: {
      RuntimeLifecycleState.ready,
      RuntimeLifecycleState.failed,
    },
    RuntimeLifecycleState.ready: {
      RuntimeLifecycleState.inferencing,
      RuntimeLifecycleState.recovering,
      RuntimeLifecycleState.failed,
    },
    RuntimeLifecycleState.inferencing: {
      RuntimeLifecycleState.ready,
      RuntimeLifecycleState.recovering,
      RuntimeLifecycleState.failed,
    },
    RuntimeLifecycleState.recovering: {
      RuntimeLifecycleState.uninitialized,
      RuntimeLifecycleState.failed,
    },
    RuntimeLifecycleState.failed: {
      RuntimeLifecycleState.recovering,
      RuntimeLifecycleState.uninitialized,
    },
  };

  // ---------------------------------------------------------------------------
  // Transition API
  // ---------------------------------------------------------------------------

  /// Attempts to move from [currentState] to [next].
  ///
  /// Returns `true` and emits on [stateStream] when the transition is valid.
  /// Returns `false` and logs a warning when the transition is not in
  /// [_allowedTransitions].
  bool transition(RuntimeLifecycleState next) {
    final allowed = _allowedTransitions[_currentState];
    if (allowed == null || !allowed.contains(next)) {
      debugPrint(
        '[RUNTIME_STATE] INVALID transition: $_currentState → $next '
        '(allowed: ${allowed ?? '{}'})',
      );
      return false;
    }
    _applyState(next);
    return true;
  }

  /// Unconditionally moves to [state], bypassing the transition table.
  ///
  /// Intended exclusively for the recovery manager and test harnesses.
  /// Every call is logged so it is auditable.
  void forceState(RuntimeLifecycleState state) {
    debugPrint(
      '[RUNTIME_STATE] FORCE transition: $_currentState → $state',
    );
    _applyState(state);
  }

  /// Closes the broadcast stream.  Call when the machine is being torn down.
  void dispose() {
    _controller.close();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _applyState(RuntimeLifecycleState next) {
    debugPrint('[RUNTIME_STATE] $next');
    _currentState = next;
    if (!_controller.isClosed) {
      _controller.add(next);
    }
  }
}
