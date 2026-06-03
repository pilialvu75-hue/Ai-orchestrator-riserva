/// FFI stream boundary helpers for the Android runtime provider.
///
/// Emits Dart token chunks and terminal responses while preserving the
/// original FFI-facing error handling and stream closure order.
part of 'runtime_core.dart';

class _AndroidFfiRuntimeExecutionBoundary {
  static void emitTokenChunk(
    StreamController<InferenceResponse> ctrl, {
    required String text,
    required String model,
  }) {
    if (ctrl.isClosed) return;
    ctrl.add(
      InferenceResponse.token(
        text: text,
        model: model,
      ),
    );
  }

  static void emitFinalChunk(
    StreamController<InferenceResponse> ctrl, {
    required String text,
    required int tokensGenerated,
    required String model,
  }) {
    if (ctrl.isClosed) return;
    ctrl.add(
      InferenceResponse.finalChunk(
        text: text,
        tokensGenerated: tokensGenerated,
        model: model,
      ),
    );
  }

  static void finishWithError(
    StreamController<InferenceResponse> ctrl,
    String message, {
    InferenceTerminalState state = InferenceTerminalState.failed,
  }) {
    if (ctrl.isClosed) return;
    ctrl.add(InferenceResponse.error(message, state: state));
    _log('[FFI_STREAM_CLOSE] reason=finish_with_error');
    _log(
      '[DART_STREAM_CLOSE] elapsed_ms=0 thread_id=${AndroidFfiRuntimeProvider._currentThreadId()} token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=-1 reason=finish_with_error',
    );
    ctrl.close();
  }

  static void finishWithRuntimeError(
    StreamController<InferenceResponse> ctrl, {
    required String stage,
    required String message,
    String? details,
    InferenceTerminalState state = InferenceTerminalState.failed,
  }) {
    final exception = RuntimeStageException(
      stage: stage,
      message: message,
      details: details,
    );
    final payload = exception.toPayload();
    _log('[GENERATION_ERROR] stage=$stage message=$message details=${details ?? ''}');
    _logAi(
      'runtime error: ${exception.toLogMessage()}',
    );
    _log(payload);
    finishWithError(ctrl, payload, state: state);
  }

  static Future<void> finishWithPartialOrRuntimeError(
    StreamController<InferenceResponse> ctrl, {
    required String stage,
    required String message,
    required String modelId,
    required String fullText,
    required int tokensGenerated,
    String? notice,
    InferenceTerminalState partialTerminalState = InferenceTerminalState.failed,
  }) async {
    if (ctrl.isClosed) return;
    if (fullText.trim().isNotEmpty) {
      if (notice != null && notice.trim().isNotEmpty) {
        _log('[STREAM_ADD] event=notice');
        ctrl.add(InferenceResponse.notice(notice));
      }
      _log('[STREAM_ADD] event=final_partial');
      ctrl.add(
        InferenceResponse(
          text: fullText,
          model: modelId,
          tokensGenerated: tokensGenerated,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          isFinal: true,
          terminalState: partialTerminalState,
        ),
      );
      _log('[FFI_STREAM_CLOSE] reason=partial_or_runtime_error');
      if (!ctrl.isClosed) {
        try {
          await ctrl.close();
        } catch (_) {}
      }
      return;
    }
    finishWithRuntimeError(
      ctrl,
      stage: stage,
      message: message,
      state: partialTerminalState,
    );
  }

  static void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }

  static void _logAi(String message) {
    AndroidFfiRuntimeProvider._logAi(message);
  }
}
