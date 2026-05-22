import 'dart:ffi';

import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ffi/ffi.dart';

class LlamaBridgeBindings {
  LlamaBridgeBindings(DynamicLibrary lib)
      : _initBackend =
            lib.lookupFunction<LlbInitBackendNative, LlbInitBackendDart>(
          'llb_init_backend',
        ),
        _createSession =
            lib.lookupFunction<LlbCreateSessionNative, LlbCreateSessionDart>(
          'llb_create_session',
        ),
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
        _sessionLastError = lib.lookupFunction<
            LlbSessionLastErrorNative,
            LlbSessionLastErrorDart>('llb_session_last_error');

  final LlbInitBackendDart _initBackend;
  final LlbCreateSessionDart _createSession;
  final LlbSessionStartGenDart _sessionStartGen;
  final LlbSessionPollTokenDart _sessionPollToken;
  final LlbSessionCancelDart _sessionCancel;
  final LlbReleaseSessionDart _releaseSession;
  final LlbSessionIsActiveDart _sessionIsActive;
  final LlbSessionLastErrorDart _sessionLastError;

  void initBackend() => _initBackend();

  int createSession(String modelPath, {int? nGpuLayers}) {
    final pathPtr = modelPath.toNativeUtf8(allocator: calloc);
    final resolvedGpuLayers = nGpuLayers != null && nGpuLayers > 0
        ? nGpuLayers
        : LlamaNativeDefaults.nGpuLayers;
    try {
      return _createSession(
        pathPtr,
        LlamaNativeDefaults.nCtx,
        LlamaNativeDefaults.nThreads,
        resolvedGpuLayers,
      );
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Starts generation for [sessionId] using the caller-owned [promptPtr].
  ///
  /// The caller is responsible for keeping [promptPtr] valid until the first
  /// token has been polled from the native side (i.e. until the first
  /// successful [pollToken] call returns a non-empty piece). Freeing the
  /// pointer before that point is undefined behaviour because the native
  /// tokenisation stage may read from it on a background thread.
  int startGeneration(
    int sessionId,
    Pointer<Utf8> promptPtr,
    int maxTokens,
    double temperature,
  ) {
    return _sessionStartGen(sessionId, promptPtr, maxTokens, temperature);
  }

  int pollToken(int sessionId, Pointer<Utf8> buf) =>
      _sessionPollToken(sessionId, buf, LlamaNativeDefaults.tokenBufferSize);

  void cancelSession(int sessionId) => _sessionCancel(sessionId);

  void releaseSession(int sessionId) => _releaseSession(sessionId);

  int sessionIsActive(int sessionId) => _sessionIsActive(sessionId);

  String sessionLastError(int sessionId) => _sessionLastError(sessionId).toDartString();
}
