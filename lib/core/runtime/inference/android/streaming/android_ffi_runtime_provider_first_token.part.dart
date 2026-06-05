part of '../../runtime_core.dart';

class _FirstTokenAttemptState {
  _FirstTokenAttemptState({
    required this.attemptId,
    required this.sessionId,
  });

  final String attemptId;
  final String sessionId;
  int estimatedTokens = 0;
  int pollIterations = 0;
  DateTime? firstTokenAt;
  bool runtimeNeedsReset = false;
  String? runtimeResetReason;
  bool runtimeResetRequested = false;
  bool cancellationDetected = false;
  bool exceptionDetected = false;
  String terminationReason = 'attempt_incomplete';
  String terminalBoundary = 'stream_scope';
  bool firstTokenAttemptClosed = false;
}

extension AndroidFfiRuntimeFirstTokenExtension on AndroidFfiRuntimeProvider {
  _FirstTokenAttemptState _beginFirstTokenAttempt({
    required String sessionId,
    required String modelId,
    required bool isForensicSelfTest,
    required int dartThreadId,
  }) {
    final attemptId =
        'fta_${DateTime.now().microsecondsSinceEpoch}_${sessionId.hashCode.toRadixString(16)}';
    _currentFirstTokenAttemptId = attemptId;
    final state = _FirstTokenAttemptState(
      attemptId: attemptId,
      sessionId: sessionId,
    );
    _log(
      '[ACTION_VARS_INITIALIZED] sessionId=$sessionId modelId=$modelId attemptId=$attemptId dartThreadId=$dartThreadId isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()} nativeSessionId=${_nativeSessionId ?? 'null'} sessionCacheSize=${_nativeSessionsByModel.length} ts=${DateTime.now().microsecondsSinceEpoch}',
    );
    _log(
      '[FIRST_TOKEN_ATTEMPT_BEGIN] attemptId=$attemptId sessionId=$sessionId'
      ' modelId=$modelId is_verification=$isForensicSelfTest',
    );
    return state;
  }

  void _classifyFirstTokenTermination({
    required _StreamFlowControlState flowState,
    required String reason,
    required String boundary,
    bool cancellation = false,
    bool exception = false,
    bool runtimeReset = false,
    _FirstTokenAttemptState? attemptState,
  }) {
    final state = attemptState;
    if (state != null) {
      state.terminationReason = reason;
      state.terminalBoundary = boundary;
      state.cancellationDetected = state.cancellationDetected || cancellation;
      state.exceptionDetected = state.exceptionDetected || exception;
      state.runtimeResetRequested = state.runtimeResetRequested || runtimeReset;
    }
    if (runtimeReset && state != null) {
      state.runtimeNeedsReset = true;
    }
  }

  void _logFirstTokenSuccessTelemetry({
    required _FirstTokenAttemptState attemptState,
    required String sessionId,
    required int nativeSessionId,
    required int dartThreadId,
    required String sanitizedPiece,
    required int pollIterations,
    required int estimatedTokens,
    required Duration elapsed,
  }) {
    _log(
      '[FFI_FIRST_TOKEN] session=$nativeSessionId elapsed_ms=${elapsed.inMilliseconds} chars=${sanitizedPiece.length} phase=$_runtimePhase',
    );
    _log(
      '[FIRST_TOKEN] elapsed_ms=${elapsed.inMilliseconds}'
      ' token_text_length=${sanitizedPiece.length}'
      ' poll_iteration=$pollIterations session=$sessionId',
    );
    _log(
      '[FIRST_TOKEN_REAL] elapsed_ms=${elapsed.inMilliseconds}'
      ' thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length}'
      ' queue_size=-1 poll_iteration=$pollIterations'
      ' token="${sanitizedPiece.replaceAll('\n', r'\n')}" token_count=$estimatedTokens',
    );
    _log(
      '[FIRST_TOKEN_SUCCESS] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
      ' sessionId=$sessionId nativeSessionId=$nativeSessionId'
      ' elapsed_ms=${elapsed.inMilliseconds}'
      ' chars=${sanitizedPiece.length} poll_iterations=$pollIterations'
      ' pre_first_token_active=false',
    );
  }

  Future<void> _handleFirstTokenWatchdogTimeout({
    required _StreamFlowControlState flowState,
    required _FirstTokenAttemptState attemptState,
    required StreamController<InferenceResponse> controller,
    required LlamaBridgeBindings bindings,
    required String sessionId,
    required String modelId,
    required int nativeSessionId,
    required DateTime startedAt,
    required Duration firstTokenDeadline,
    required int dartThreadId,
    required bool isForensicSelfTest,
  }) async {
    _classifyFirstTokenTermination(
      flowState: flowState,
      attemptState: attemptState,
      reason: 'first_token_watchdog',
      boundary: 'poll_loop',
      runtimeReset: true,
    );
    _setPhase(RuntimePhase.stalled);
    _log(
      '[FFI_TIMEOUT] session=$sessionId stage=first_token_watchdog'
      ' timeout_ms=${firstTokenDeadline.inMilliseconds}',
    );
    _safeCancel(bindings, nativeSessionId);
    clearRuntimeVerification();
    attemptState.runtimeNeedsReset = true;
    attemptState.runtimeResetReason = 'first_token_watchdog';
    final elapsed = DateTime.now().difference(startedAt);
    _log(
      '[STREAM_TIMEOUT] reason=no_first_token elapsed_ms=${elapsed.inMilliseconds}'
      ' timeout_ms=${firstTokenDeadline.inMilliseconds} session=$sessionId',
    );
    _log(
      '[STALL] reason=first_token_watchdog elapsed_ms=${elapsed.inMilliseconds}'
      ' no_token_produced=true session=$sessionId',
    );
    _log(
      '[FIRST_TOKEN_TIMEOUT] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=${attemptState.pollIterations} timeout_ms=${firstTokenDeadline.inMilliseconds}',
    );
    _log(
      '[FIRST_TOKEN_FAILURE] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
      ' sessionId=$sessionId reason=first_token_watchdog'
      ' elapsed_ms=${elapsed.inMilliseconds} timeout_ms=${firstTokenDeadline.inMilliseconds}'
      ' poll_iterations=${attemptState.pollIterations} pre_first_token_active=$_preFirstTokenActive',
    );
    _log(
      '[TERMINAL_STATE] state=stalled reason=first_token_watchdog'
      ' elapsed_ms=${elapsed.inMilliseconds} no_token_produced=true',
    );
    _updateRuntimeStatus(
      LocalRuntimeStatus.stalled,
      message: 'Runtime stalled',
      tokensGenerated: attemptState.estimatedTokens,
      elapsed: elapsed,
      startedAt: startedAt,
    );
    _logAi('inference timeout');
    _finishWithRuntimeError(
      controller,
      stage: 'stalled',
      message: isForensicSelfTest
          ? 'FIRST_TOKEN_TIMEOUT'
          : 'Local model stalled during inference.',
    );
  }

  void _finalizeFirstTokenAttempt(_FirstTokenAttemptState attemptState) {
    if (attemptState.firstTokenAttemptClosed) {
      return;
    }
    attemptState.firstTokenAttemptClosed = true;
    final endAttemptId = _currentFirstTokenAttemptId ?? attemptState.attemptId;
    final preFirstTokenActiveAtEnd = _preFirstTokenActive;
    final runtimeResetRequestedAtEnd =
        attemptState.runtimeResetRequested || attemptState.runtimeNeedsReset;
    _log(
      '[FIRST_TOKEN_ATTEMPT_END] attemptId=$endAttemptId'
      ' sessionId=${attemptState.sessionId} generated_tokens=${attemptState.estimatedTokens}'
      ' termination_reason=${attemptState.terminationReason}'
      ' terminal_boundary=${attemptState.terminalBoundary}'
      ' first_token_received=${attemptState.firstTokenAt != null}'
      ' pre_first_token_active=$preFirstTokenActiveAtEnd'
      ' runtime_reset_requested=$runtimeResetRequestedAtEnd'
      ' cancellation_detected=${attemptState.cancellationDetected}'
      ' exception_detected=${attemptState.exceptionDetected}'
      ' runtime_needs_reset=${attemptState.runtimeNeedsReset}'
      ' reset_reason=${attemptState.runtimeResetReason ?? 'none'}',
    );
    _preFirstTokenActive = false;
    _currentFirstTokenAttemptId = null;
  }
}
