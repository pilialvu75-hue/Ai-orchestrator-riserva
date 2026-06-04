part of runtime_core;

class _AndroidFfiLifecycleSubsystem {
  _AndroidFfiLifecycleSubsystem(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  void updateRuntimeStatus(
    LocalRuntimeStatus status, {
    String? message,
    int? tokensGenerated,
    Duration? elapsed,
    DateTime? startedAt,
    bool resetProgress = false,
    required String reason,
    required String origin,
  }) {
    if (_owner._inVerificationScope) {
      _log(
        '[VERIFICATION_UI_IGNORED] verification_scope=true status=${status.name} reason=$reason origin=$origin',
      );
      return;
    }
    final previous = _owner.monitor.state.status;
    final transitionReason =
        reason == AndroidFfiRuntimeProvider._autoTransitionReason
            ? defaultReasonFor(status)
            : reason;
    _owner.monitor.update(
      status,
      message: message,
      tokensGenerated: tokensGenerated,
      elapsed: elapsed,
      startedAt: startedAt,
      resetProgress: resetProgress,
    );
    traceStatePath(
      from: previous,
      to: status,
      reason: transitionReason,
      origin: origin,
    );
    syncLifecycleState(status, reason: transitionReason, origin: origin);
  }

  void syncLifecycleState(
    LocalRuntimeStatus status, {
    required String reason,
    required String origin,
  }) {
    switch (status) {
      case LocalRuntimeStatus.uninitialized:
      case LocalRuntimeStatus.modelMissing:
        _owner.runtimeStateMachine.reset();
        emitStateReset(reason: reason, origin: origin);
        return;
      case LocalRuntimeStatus.runtimeUnavailable:
        _owner.runtimeStateMachine.markHealthy();
        return;
      case LocalRuntimeStatus.loading:
      case LocalRuntimeStatus.tokenizing:
        _owner.runtimeStateMachine.markLoading();
        return;
      case LocalRuntimeStatus.ready:
        _owner.runtimeStateMachine.markVerified();
        return;
      case LocalRuntimeStatus.completed:
        _owner.runtimeStateMachine.markInferenceCompleted();
        return;
      case LocalRuntimeStatus.inferencing:
      case LocalRuntimeStatus.streaming:
        _owner.runtimeStateMachine.markInferencing();
        return;
      case LocalRuntimeStatus.timedOut:
      case LocalRuntimeStatus.stalled:
      case LocalRuntimeStatus.ffiMissing:
      case LocalRuntimeStatus.failed:
        _owner.runtimeStateMachine.markFailed();
        return;
    }
  }

  String defaultReasonFor(LocalRuntimeStatus status) {
    switch (status) {
      case LocalRuntimeStatus.loading:
        return 'runtime_check_begin';
      case LocalRuntimeStatus.runtimeUnavailable:
        return 'runtime_not_verified';
      case LocalRuntimeStatus.uninitialized:
        return 'runtime_reset';
      case LocalRuntimeStatus.ready:
        return 'runtime_verified';
      default:
        return 'status_update';
    }
  }

  String expectedNextFor(LocalRuntimeStatus status) {
    switch (status) {
      case LocalRuntimeStatus.loading:
        return 'runtime_unavailable_or_ready';
      case LocalRuntimeStatus.runtimeUnavailable:
        return 'ready_or_pre_stream_inference';
      case LocalRuntimeStatus.uninitialized:
        return 'loading';
      case LocalRuntimeStatus.ready:
        return 'pre_stream_inference_or_inferencing';
      default:
        return 'runtime_progression';
    }
  }

  void traceStatePath({
    required LocalRuntimeStatus from,
    required LocalRuntimeStatus to,
    required String reason,
    required String origin,
  }) {
    final now = DateTime.now();
    final elapsedSinceLast = _owner._lastTransitionAt == null
        ? null
        : now.difference(_owner._lastTransitionAt!);
    final repeated = from == to;
    _owner._transitionCounter++;
    _owner._activeTransitionId = _owner._transitionCounter;
    _owner._lastTransitionAt = now;
    _owner._lastTransitionReason = reason;
    _owner._lastTransitionOrigin = origin;
    _log(
      '[STATE_PATH] path=${from.name}->${to.name} reason=$reason origin=$origin transition_id=${_owner._activeTransitionId} transition_ts=${now.toIso8601String()} elapsed_since_last_transition_ms=${elapsedSinceLast?.inMilliseconds ?? -1} repeated=$repeated',
    );
    _log('[EXPECTED_NEXT] current=${to.name} next=${expectedNextFor(to)}');

    if (from == LocalRuntimeStatus.runtimeUnavailable &&
        to == LocalRuntimeStatus.loading &&
        elapsedSinceLast != null &&
        elapsedSinceLast < AndroidFfiRuntimeProvider._reentryWarnThreshold) {
      _owner._reentryCount++;
      _log(
        '[REENTRY_DETECTED] from=${from.name} to=${to.name} elapsed_ms=${elapsedSinceLast.inMilliseconds} origin=$origin reentry_count=${_owner._reentryCount}',
      );
    }

    if (to == LocalRuntimeStatus.runtimeUnavailable &&
        !_owner._streamInferenceEntered) {
      _log(
        '[LIFECYCLE_INTERRUPTION] expected_next=PRE_STREAM_INFERENCE last_state=${to.name} last_transition_id=${_owner._activeTransitionId} reason=unexpected_reset_before_inference',
      );
      _log(
        '[FIRST_RESPONSE_BLOCKED] boundary=pre_stream_inference last_known_state=${to.name} last_transition_reason=${_owner._lastTransitionReason} last_transition_origin=${_owner._lastTransitionOrigin}',
      );
      if (_owner._reentryCount >=
          AndroidFfiRuntimeProvider._reentryLoopBlockThreshold) {
        _log(
          '[FIRST_RESPONSE_BLOCKED] boundary=runtime_verification_loop reentry_count=${_owner._reentryCount} elapsed_ms=${elapsedSinceLast?.inMilliseconds ?? -1}',
        );
      }
    }
  }

  void emitStateReset({
    required String reason,
    required String origin,
  }) {
    final now = DateTime.now();
    final elapsedSinceLast = _owner._lastTransitionAt == null
        ? null
        : now.difference(_owner._lastTransitionAt!);
    _log(
      '[STATE_RESET] reason=$reason origin=$origin elapsed_since_last_transition_ms=${elapsedSinceLast?.inMilliseconds ?? -1}',
    );
  }

  String inferCallerFromStack() {
    final lines = StackTrace.current.toString().split('\n');
    if (lines.length <=
        AndroidFfiRuntimeProvider._clearVerificationCallerFrameIndex) {
      return 'unknown_caller';
    }
    final caller =
        lines[AndroidFfiRuntimeProvider._clearVerificationCallerFrameIndex]
            .trim();
    return caller.isEmpty ? 'unknown_caller' : caller;
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }
}
