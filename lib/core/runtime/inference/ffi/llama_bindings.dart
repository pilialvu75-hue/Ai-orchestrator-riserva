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

  int createSession(String modelPath) {
    final pathPtr = modelPath.toNativeUtf8(allocator: calloc);
    try {
      return _createSession(
        pathPtr,
        LlamaNativeDefaults.nCtx,
        LlamaNativeDefaults.nThreads,
      );
    } finally {
      calloc.free(pathPtr);
    }
  }

  int startGeneration(int sessionId, String prompt, int maxTokens, double temperature) {
    final promptPtr = prompt.toNativeUtf8(allocator: calloc);
    try {
      return _sessionStartGen(sessionId, promptPtr, maxTokens, temperature);
    } finally {
      calloc.free(promptPtr);
    }
  }

  int pollToken(int sessionId, Pointer<Utf8> buf) =>
      _sessionPollToken(sessionId, buf, LlamaNativeDefaults.tokenBufferSize);

  void cancelSession(int sessionId) => _sessionCancel(sessionId);

  void releaseSession(int sessionId) => _releaseSession(sessionId);

  int sessionIsActive(int sessionId) => _sessionIsActive(sessionId);

  String sessionLastError(int sessionId) => _sessionLastError(sessionId).toDartString();
}
