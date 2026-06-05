part of '../../runtime_core.dart';

class _TerminalStateContext {
  _TerminalStateContext({
    required this.controller,
    required this.bindings,
    required this.sessionId,
    required this.modelId,
    required this.startedAt,
    required this.estimatedTokens,
    required this.firstTokenAt,
    required this.runtimeNeedsReset,
    required this.runtimeResetReason,
    required this.tokenBufRaw,
    required this.attemptState,
  });

  final StreamController<InferenceResponse> controller;
  final LlamaBridgeBindings bindings;
  final String sessionId;
  final String modelId;
  final DateTime startedAt;
  final int estimatedTokens;
  final DateTime? firstTokenAt;
  final bool runtimeNeedsReset;
  final String? runtimeResetReason;
  final Pointer<Uint8> tokenBufRaw;
  final _FirstTokenAttemptState attemptState;
}

extension AndroidFfiRuntimeTerminalStateExtension on AndroidFfiRuntimeProvider {
  Future<void> _fatalEarlyExit({
    required _StreamFlowControlState flowState,
    required StreamController<InferenceResponse> controller,
    required String sessionId,
    required String branch,
    required String reason,
    required String stage,
    String? details,
    InferenceTerminalState state = InferenceTerminalState.failed,
  }) async {
    _log(
      '[FFI_FATAL_EARLY_EXIT] session=$sessionId branch=$branch reason=$reason',
    );
    _log(
      '[FFI_BRANCH_RETURN] session=$sessionId branch=$branch reason=$reason'
      ' first_ffi_attempted=${flowState.firstFfiInvocationAttempted} first_ffi_completed=${flowState.firstFfiInvocationCompleted}',
    );
    if (!controller.isClosed) {
      _finishWithRuntimeError(
        controller,
        stage: stage,
        message: reason,
        details: details,
        state: state,
      );
    }
  }

  Future<void> _finalizeStreamingTerminalState(
    _TerminalStateContext context,
  ) async {
    if (context.runtimeNeedsReset) {
      _safeResetRuntime(
        context.bindings,
        reason: context.runtimeResetReason ?? 'runtime_recovery',
      );
    }
    final terminalState = monitor.state.status;
    _log(
      '[TERMINAL_STATE] state=${terminalState.name}'
      ' generated_tokens=${context.estimatedTokens}'
      ' elapsed_ms=${DateTime.now().difference(context.startedAt).inMilliseconds}'
      ' first_token=${context.firstTokenAt != null} ffi_phase=$_currentFfiPhase',
    );
    if (terminalState == LocalRuntimeStatus.loading ||
        terminalState == LocalRuntimeStatus.tokenizing ||
        terminalState == LocalRuntimeStatus.inferencing ||
        terminalState == LocalRuntimeStatus.streaming) {
      _updateRuntimeStatus(
        LocalRuntimeStatus.ready,
        message: 'Runtime verified and ready for the next prompt.',
        tokensGenerated: 0,
        elapsed: Duration.zero,
        startedAt: null,
        resetProgress: true,
      );
    }
    calloc.free(context.tokenBufRaw);
    try {
      _releaseInferenceSlot(context.sessionId);
    } catch (e, st) {
      _log('Slot release failed but forced continuation: $e\n$st');
    }
    final currentController = context.controller;
    try {
      if (!currentController.isClosed) {
        await currentController.close();
      }
    } catch (e, st) {
      _log('Controller close non-fatal error swallowed safely: $e\n$st');
    }
    _finalizeFirstTokenAttempt(context.attemptState);
  }
}
