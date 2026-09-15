import 'dart:ffi';

import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ffi/ffi.dart';

export 'package:ai_orchestrator/core/runtime/inference/native_token_context_budget.dart';

class LlamaBridgeBindings {
  LlamaBridgeBindings(DynamicLibrary lib)
      : _initBackend =
            lib.lookupFunction<LlbInitBackendNative, LlbInitBackendDart>(
          'llb_init_backend',
        ),
        _gpuBackendName = lib.lookupFunction<
            LlbGpuBackendNameNative,
            LlbGpuBackendNameDart>('llb_gpu_backend_name'),
        _gpuBackendReason = lib.lookupFunction<
            LlbGpuBackendReasonNative,
            LlbGpuBackendReasonDart>('llb_gpu_backend_reason'),
        _createSession =
            lib.lookupFunction<LlbCreateSessionNative, LlbCreateSessionDart>(
          'llb_create_session',
        ),
        _sessionTokenCount = lib.lookupFunction<
            LlbSessionTokenCountNative,
            LlbSessionTokenCountDart>('llb_session_token_count'),
        _sessionStartGen =
            lib.lookupFunction<LlbSessionStartGenNative, LlbSessionStartGenDart>(
          'llb_session_start_gen',
        ),
        _sessionPollToken =
            lib.lookupFunction<LlbSessionPollTokenNative, LlbSessionPollTokenDart>(
          'llb_session_poll_token',
        ),
        _sessionCancel =
            lib.lookupFunction<LlbSessionCancelNative, LlbSessionCancelDart>(
          'llb_session_cancel',
        ),
        _releaseSession =
            lib.lookupFunction<LlbReleaseSessionNative, LlbReleaseSessionDart>(
          'llb_release_session',
        ),
        _sessionIsActive =
            lib.lookupFunction<LlbSessionIsActiveNative, LlbSessionIsActiveDart>(
          'llb_session_is_active',
        ),
        _sessionIsGenerating =
            lib.lookupFunction<LlbSessionIsActiveNative, LlbSessionIsActiveDart>(
          'llb_session_is_generating',
        ),
        _sessionLastError = lib.lookupFunction<
            LlbSessionLastErrorNative,
            LlbSessionLastErrorDart>('llb_session_last_error');

  static LlamaBridgeBindings? _currentBudgetBindings;
  static int? _currentBudgetSessionId;

  final LlbInitBackendDart _initBackend;
  final LlbGpuBackendNameDart _gpuBackendName;
  final LlbGpuBackendReasonDart _gpuBackendReason;
  final LlbCreateSessionDart _createSession;
  final LlbSessionTokenCountDart _sessionTokenCount;
  final LlbSessionStartGenDart _sessionStartGen;
  final LlbSessionPollTokenDart _sessionPollToken;
  final LlbSessionCancelDart _sessionCancel;
  final LlbReleaseSessionDart _releaseSession;
  final LlbSessionIsActiveDart _sessionIsActive;
  final LlbSessionIsActiveDart _sessionIsGenerating;
  final LlbSessionLastErrorDart _sessionLastError;

  void initBackend() => _initBackend();

  String gpuBackendName() => _gpuBackendName().toDartString();

  String gpuBackendReason() => _gpuBackendReason().toDartString();

  int createSession(
    String modelPath, {
    int nGpuLayers = LlamaNativeDefaults.nGpuLayers,
  }) {
    final pathPtr = modelPath.toNativeUtf8(allocator: calloc);
    try {
      return _createSession(
        pathPtr,
        LlamaNativeDefaults.nCtx,
        LlamaNativeDefaults.nThreads,
        nGpuLayers,
      );
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Counts tokens with the exact vocabulary of the loaded native session.
  ///
  /// This uses the same llama.cpp tokenizer configuration as generation
  /// (add_special=true, parse_special=true), so prompt budgeting can be based
  /// on the model's real token count instead of character heuristics.
  int countTokens(int sessionId, String text) {
    if (sessionId <= 0) {
      throw StateError(
        'Cannot count tokens with invalid sessionId=$sessionId.',
      );
    }

    final activeState = _sessionIsActive(sessionId);
    if (activeState != 1) {
      throw StateError(
        'Cannot count tokens on inactive native session '
        '(sessionId=$sessionId, activeState=$activeState).',
      );
    }

    final textPtr = text.toNativeUtf8(allocator: calloc);
    try {
      final count = _sessionTokenCount(sessionId, textPtr);
      if (count < 0) {
        final lastError = _sessionLastError(sessionId).toDartString().trim();
        final suffix = lastError.isEmpty ? '' : ' Native error: $lastError';
        throw StateError(
          'Native token count failed (sessionId=$sessionId, code=$count).$suffix',
        );
      }
      return count;
    } finally {
      calloc.free(textPtr);
    }
  }

  /// Returns an exact-token counter for the native session most recently
  /// validated as active on this isolate.
  ///
  /// Generation startup calls [sessionIsActive] synchronously immediately
  /// before composing the prompt, so this exposes that exact RuntimeSession to
  /// the prompt-budgeting layer without leaking native pointers or model/vocab
  /// handles across the FFI boundary.
  static int? countTokensForCurrentSession(String text) {
    final bindings = _currentBudgetBindings;
    final sessionId = _currentBudgetSessionId;
    if (bindings == null || sessionId == null || sessionId <= 0) {
      return null;
    }
    if (bindings._sessionIsActive(sessionId) != 1) {
      _currentBudgetBindings = null;
      _currentBudgetSessionId = null;
      return null;
    }
    return bindings.countTokens(sessionId, text);
  }

  /// Starts generation for [sessionId] using the caller-owned [promptPtr].
  ///
  /// The caller is responsible for keeping [promptPtr] valid until the first
  /// token has been polled from the native side. The native generation worker
  /// may still access the prompt while tokenisation is in progress.
  ///
  /// The session-active check immediately before the FFI call is intentional:
  /// the first command must never enter native generation with an already
  /// inactive/released session. A failed check is converted into a controlled
  /// Dart error instead of invoking the native function with an invalid
  /// lifecycle state.
  int startGeneration(
    int sessionId,
    Pointer<Utf8> promptPtr,
    int maxTokens,
    double temperature,
  ) {
    if (sessionId <= 0) {
      throw StateError(
        'Cannot start native generation with invalid sessionId=$sessionId.',
      );
    }

    final activeState = _sessionIsActive(sessionId);

    if (activeState != 1) {
      final lastError = _sessionLastError(sessionId).toDartString().trim();
      final suffix =
          lastError.isEmpty ? '' : ' Native error: $lastError';

      throw StateError(
        'Native session is inactive before startGeneration '
        '(sessionId=$sessionId, activeState=$activeState).$suffix',
      );
    }

    return _sessionStartGen(
      sessionId,
      promptPtr,
      maxTokens,
      temperature,
    );
  }

  int pollToken(int sessionId, Pointer<Utf8> buf) =>
      _sessionPollToken(
        sessionId,
        buf,
        LlamaNativeDefaults.tokenBufferSize,
      );

  void cancelSession(int sessionId) => _sessionCancel(sessionId);

  void releaseSession(int sessionId) {
    if (_currentBudgetBindings == this &&
        _currentBudgetSessionId == sessionId) {
      _currentBudgetBindings = null;
      _currentBudgetSessionId = null;
    }
    _releaseSession(sessionId);
  }

  int sessionIsActive(int sessionId) {
    final state = _sessionIsActive(sessionId);
    if (state == 1) {
      _currentBudgetBindings = this;
      _currentBudgetSessionId = sessionId;
    } else if (_currentBudgetBindings == this &&
        _currentBudgetSessionId == sessionId) {
      _currentBudgetBindings = null;
      _currentBudgetSessionId = null;
    }
    return state;
  }

  int sessionIsGenerating(int sessionId) => _sessionIsGenerating(sessionId);

  String sessionLastError(int sessionId) =>
      _sessionLastError(sessionId).toDartString();
}
