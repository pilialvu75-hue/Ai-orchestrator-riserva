part of 'android_ffi_runtime_provider.dart';

class _AndroidFfiNativeSessionSubsystem {
  _AndroidFfiNativeSessionSubsystem(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  int ensureNativeSession(LlamaBridgeBindings bindings, String modelPath) {
    try {
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1952 | Function: _ensureNativeSession() | BEFORE entry',
      );
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1955 | Function: _ensureNativeSession() | BEFORE reuse check',
      );
      final existingSessionId = _owner._nativeSessionsByModel[modelPath];
      if (existingSessionId != null &&
          bindings.sessionIsActive(existingSessionId) == 1) {
        markSessionAsMostRecentlyUsed(modelPath);
        _owner._nativeSessionId = existingSessionId;
        _log('[SESSION_CREATE_OK] reusing session=$existingSessionId path=$modelPath');
        _log(
            '[FFI_CREATE_SESSION_OK] reusing=true session=$existingSessionId path=$modelPath');
        _log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1963 | Function: _ensureNativeSession() | AFTER reuse return',
        );
        return existingSessionId;
      }

      if (existingSessionId != null) {
        releaseNativeSessionByModelPath(
          bindings,
          modelPath,
          reason: 'inactive_existing_session',
        );
      }

      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1969 | Function: _ensureNativeSession() | BEFORE LRU eviction check',
      );
      evictLeastRecentlyUsedSessionIfNeeded(bindings);
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1973 | Function: _ensureNativeSession() | AFTER LRU eviction check',
      );

      _log('[FFI_CREATE_SESSION] entering createSession path=$modelPath');
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1978 | Function: _ensureNativeSession() | BEFORE bindings.createSession()',
      );
      const desiredGpuLayers = LlamaNativeDefaults.nGpuLayers;
      _log('[GPU_INIT] path=$modelPath requested_gpu_layers=$desiredGpuLayers');
      int created =
          bindings.createSession(modelPath, nGpuLayers: desiredGpuLayers);
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1982 | Function: _ensureNativeSession() | AFTER bindings.createSession()',
      );
      _log(
          '[FFI_CREATE_SESSION_RETURN] returned_session_id=$created path=$modelPath gpu_layers=$desiredGpuLayers');

      if (created <= 0 && desiredGpuLayers > 0) {
        _log(
          '[GPU_FALLBACK] path=$modelPath gpu_layers=$desiredGpuLayers failed=$created reason=session_create_error retrying_with_cpu',
        );
        created = bindings.createSession(modelPath, nGpuLayers: 0);
        _log(
          '[FFI_CREATE_SESSION_RETURN] returned_session_id=$created path=$modelPath gpu_layers=0 fallback=cpu',
        );
      }
      if (created <= 0) {
        _log('[SESSION_CREATE_FAIL] path=$modelPath session=$created');
        final err = _safeLastError(bindings, created);
        throw StateError('Native session creation failed: $err');
      }
      if (bindings.sessionIsActive(created) != 1) {
        _log(
            '[SESSION_CREATE_FAIL] path=$modelPath session=$created inactive_after_create');
        final err = _safeLastError(bindings, created);
        throw StateError('Native session inactive after create: $err');
      }

      _owner._nativeSessionId = created;
      _owner._nativeSessionsByModel[modelPath] = created;
      markSessionAsMostRecentlyUsed(modelPath);
      _log('[SESSION_CREATE_OK] path=$modelPath session=$created');
      _log('[FFI_CREATE_SESSION_OK] path=$modelPath session=$created');
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2001 | Function: _ensureNativeSession() | AFTER exit',
      );
      return created;
    } catch (e, stackTrace) {
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC_EXCEPTION - File: android_ffi_runtime_provider.dart | Line: 2006 | Function: _ensureNativeSession() | BEFORE rethrow after exception: $e \n $stackTrace',
      );
      rethrow;
    }
  }

  void releaseNativeSessionByModelPath(
    LlamaBridgeBindings bindings,
    String modelPath, {
    required String reason,
  }) {
    final sessionId = _owner._nativeSessionsByModel.remove(modelPath);
    if (sessionId == null) return;
    try {
      _log('[FFI_RELEASE] session=$sessionId path=$modelPath reason=$reason');
      bindings.releaseSession(sessionId);
    } catch (error) {
      _log(
          '[FFI_RELEASE] session=$sessionId path=$modelPath reason=$reason failed: $error');
    } finally {
      if (_owner._nativeSessionId == sessionId) {
        _owner._nativeSessionId = null;
      }
    }
  }

  void evictLeastRecentlyUsedSessionIfNeeded(LlamaBridgeBindings bindings) {
    if (_owner._nativeSessionsByModel.length < _owner._maxActiveNativeSessions) {
      return;
    }
    final evictedModelPath = _owner._nativeSessionsByModel.keys.first;
    final evictedSessionId =
        _owner._nativeSessionsByModel.remove(evictedModelPath);
    if (evictedSessionId == null) {
      return;
    }
    _log(
      '[SESSION_EVICT] strategy=lru path=$evictedModelPath session=$evictedSessionId max_active=${_owner._maxActiveNativeSessions}',
    );
    try {
      bindings.releaseSession(evictedSessionId);
    } catch (error) {
      _log(
        '[SESSION_EVICT] strategy=lru path=$evictedModelPath session=$evictedSessionId release_failed=$error',
      );
    } finally {
      if (_owner._nativeSessionId == evictedSessionId) {
        _owner._nativeSessionId = null;
      }
    }
  }

  void markSessionAsMostRecentlyUsed(String modelPath) {
    final lastModelPath = _owner._nativeSessionsByModel.isEmpty
        ? null
        : _owner._nativeSessionsByModel.keys.last;
    if (lastModelPath == modelPath) return;
    final sessionId = _owner._nativeSessionsByModel.remove(modelPath);
    if (sessionId == null) return;
    _owner._nativeSessionsByModel[modelPath] = sessionId;
  }

  void releaseAllNativeSessions(
    LlamaBridgeBindings bindings, {
    required String reason,
  }) {
    final entries = _owner._nativeSessionsByModel.entries.toList(growable: false);
    for (final entry in entries) {
      try {
        _log(
          '[FFI_RELEASE] session=${entry.value} path=${entry.key} reason=$reason',
        );
        bindings.releaseSession(entry.value);
      } catch (error) {
        _log(
          '[FFI_RELEASE] session=${entry.value} path=${entry.key} reason=$reason failed: $error',
        );
      }
    }
    _owner._nativeSessionsByModel.clear();
    _owner._nativeSessionId = null;
  }

  void safeCancel(LlamaBridgeBindings bindings, int sessionId) {
    try {
      _log('[FFI_CANCEL] session=$sessionId');
      bindings.cancelSession(sessionId);
    } catch (error) {
      _log('[MODEL_EXECUTION] llb_session_cancel failed: $error');
    }
  }

  void safeResetRuntime(
    LlamaBridgeBindings bindings, {
    required String reason,
  }) {
    try {
      _log('[MODEL_EXECUTION] resetting native runtime: $reason');
      final sessionId = _owner._nativeSessionId;
      if (sessionId != null) {
        _log(
            '[MODEL_EXECUTION] llb_session_is_active before reset: ${bindings.sessionIsActive(sessionId)}');
        safeCancel(bindings, sessionId);
      }
      releaseAllNativeSessions(bindings, reason: reason);
    } catch (error) {
      _log('[MODEL_EXECUTION] runtime reset failed: $error');
    }
  }

  String _safeLastError(LlamaBridgeBindings bindings, int sessionId) {
    return AndroidFfiRuntimeProvider._safeLastError(bindings, sessionId);
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }
}
