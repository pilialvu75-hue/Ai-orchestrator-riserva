part of '../../runtime_core.dart';


class _AndroidFfiNativeSessionSubsystem {
  _AndroidFfiNativeSessionSubsystem(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  int ensureNativeSession(
    LlamaBridgeBindings bindings,
    String modelPath, {
    String? modelId,
  }) {
    try {
      final isolateHash = AndroidFfiRuntimeProvider._currentThreadId();
      final cacheSizeBeforeLookup = _owner._nativeSessionsByModel.length;
      AndroidFfiRuntimeProvider._log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1952 | Function: _ensureNativeSession() | BEFORE entry',
      );
      AndroidFfiRuntimeProvider._log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1955 | Function: _ensureNativeSession() | BEFORE reuse check',
      );
      AndroidFfiRuntimeProvider._log(
        '[NATIVE_SESSION_CACHE_LOOKUP] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
        ' isolateHash=$isolateHash session_cache_size=$cacheSizeBeforeLookup'
        ' active_inference_sessions=${_owner._activeInferenceSessions.length}',
      );
      if (_owner._activeInferenceSessions.length > 1) {
        AndroidFfiRuntimeProvider._log(
          '[NATIVE_SESSION_CONCURRENT_ACCESS] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
          ' active_inference_sessions=${_owner._activeInferenceSessions.length}'
          ' isolateHash=$isolateHash',
        );
      }
      final existingSessionId = _owner._nativeSessionsByModel[modelPath];
      if (existingSessionId != null &&
          bindings.sessionIsActive(existingSessionId) == 1) {
        final reusedPointerHex =
            '0x${existingSessionId.toUnsigned(64).toRadixString(16)}';
        final reusedPointerAddress = existingSessionId > 0
            ? Pointer<Void>.fromAddress(existingSessionId).address
            : 0;
        markSessionAsMostRecentlyUsed(modelPath);
        _owner._nativeSessionId = existingSessionId;
        AndroidFfiRuntimeProvider._log(
          '[NATIVE_SESSION_CACHE_HIT] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
          ' nativeSessionId=$existingSessionId pointer_hex=$reusedPointerHex'
          ' pointer_address=$reusedPointerAddress session_active=1'
          ' isolateHash=$isolateHash session_cache_size=${_owner._nativeSessionsByModel.length}',
        );
        AndroidFfiRuntimeProvider._log(
          '[NATIVE_SESSION_REUSE] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
          ' nativeSessionId=$existingSessionId pointer_hex=$reusedPointerHex'
          ' pointer_address=$reusedPointerAddress session_active=1'
          ' isolateHash=$isolateHash session_cache_size=${_owner._nativeSessionsByModel.length}',
        );
        AndroidFfiRuntimeProvider._log('[SESSION_CREATE_OK] reusing session=$existingSessionId path=$modelPath');
        AndroidFfiRuntimeProvider._log(
            '[FFI_CREATE_SESSION_OK] reusing=true session=$existingSessionId path=$modelPath');
        AndroidFfiRuntimeProvider._log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1963 | Function: _ensureNativeSession() | AFTER reuse return',
        );
        return existingSessionId;
      }

      if (existingSessionId != null) {
        final stalePointerHex =
            '0x${existingSessionId.toUnsigned(64).toRadixString(16)}';
        final stalePointerAddress = existingSessionId > 0
            ? Pointer<Void>.fromAddress(existingSessionId).address
            : 0;
        final staleActiveState = bindings.sessionIsActive(existingSessionId);
        AndroidFfiRuntimeProvider._log(
          '[NATIVE_SESSION_CACHE_MISS] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
          ' reason=inactive_cached_session nativeSessionId=$existingSessionId'
          ' pointer_hex=$stalePointerHex pointer_address=$stalePointerAddress'
          ' session_active=$staleActiveState isolateHash=$isolateHash'
          ' session_cache_size=${_owner._nativeSessionsByModel.length}',
        );
        AndroidFfiRuntimeProvider._log(
          '[NATIVE_SESSION_STALE_POINTER] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
          ' nativeSessionId=$existingSessionId pointer_hex=$stalePointerHex'
          ' pointer_address=$stalePointerAddress session_active=$staleActiveState'
          ' isolateHash=$isolateHash',
        );
        releaseNativeSessionByModelPath(
          bindings,
          modelPath,
          reason: 'inactive_existing_session',
        );
      } else {
        AndroidFfiRuntimeProvider._log(
          '[NATIVE_SESSION_CACHE_MISS] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
          ' reason=not_cached nativeSessionId=null pointer_hex=0x0 pointer_address=0'
          ' session_active=0 isolateHash=$isolateHash'
          ' session_cache_size=${_owner._nativeSessionsByModel.length}',
        );
      }

      AndroidFfiRuntimeProvider._log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1969 | Function: _ensureNativeSession() | BEFORE LRU eviction check',
      );
      evictLeastRecentlyUsedSessionIfNeeded(bindings);
      AndroidFfiRuntimeProvider._log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1973 | Function: _ensureNativeSession() | AFTER LRU eviction check',
      );

      AndroidFfiRuntimeProvider._log('[FFI_CREATE_SESSION] entering createSession path=$modelPath');
      AndroidFfiRuntimeProvider._log(
        '[FORENSIC_BEFORE_LLB_CREATE_SESSION] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
        ' nativeSessionId=0 pointer_hex=0x0 pointer_address=0'
        ' session_active=0 isolateHash=$isolateHash'
        ' thread_id=$isolateHash session_cache_size=${_owner._nativeSessionsByModel.length}',
      );
      AndroidFfiRuntimeProvider._log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1978 | Function: _ensureNativeSession() | BEFORE bindings.createSession()',
      );
      const desiredGpuLayers = LlamaNativeDefaults.nGpuLayers;
      AndroidFfiRuntimeProvider._log('[GPU_INIT] path=$modelPath requested_gpu_layers=$desiredGpuLayers');
      int created =
          bindings.createSession(modelPath, nGpuLayers: desiredGpuLayers);
      AndroidFfiRuntimeProvider._log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1982 | Function: _ensureNativeSession() | AFTER bindings.createSession()',
      );
      final createdPointerHex = '0x${created.toUnsigned(64).toRadixString(16)}';
      final createdPointerAddress =
          created > 0 ? Pointer<Void>.fromAddress(created).address : 0;
      final createdActiveState =
          created > 0 ? bindings.sessionIsActive(created) : 0;
      AndroidFfiRuntimeProvider._log(
        '[FORENSIC_AFTER_LLB_CREATE_SESSION] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
        ' nativeSessionId=$created pointer_hex=$createdPointerHex'
        ' pointer_address=$createdPointerAddress session_active=$createdActiveState'
        ' isolateHash=$isolateHash thread_id=$isolateHash'
        ' session_cache_size=${_owner._nativeSessionsByModel.length}',
      );
      AndroidFfiRuntimeProvider._log(
          '[FFI_CREATE_SESSION_RETURN] returned_session_id=$created path=$modelPath gpu_layers=$desiredGpuLayers');

      if (created <= 0 && desiredGpuLayers > 0) {
        AndroidFfiRuntimeProvider._log(
          '[GPU_FALLBACK] path=$modelPath gpu_layers=$desiredGpuLayers failed=$created reason=session_create_error retrying_with_cpu',
        );
        AndroidFfiRuntimeProvider._log(
          '[FORENSIC_BEFORE_LLB_CREATE_SESSION] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
          ' nativeSessionId=0 pointer_hex=0x0 pointer_address=0'
          ' session_active=0 isolateHash=$isolateHash'
          ' thread_id=$isolateHash session_cache_size=${_owner._nativeSessionsByModel.length}'
          ' fallback=cpu',
        );
        created = bindings.createSession(modelPath, nGpuLayers: 0);
        final fallbackPointerHex = '0x${created.toUnsigned(64).toRadixString(16)}';
        final fallbackPointerAddress =
            created > 0 ? Pointer<Void>.fromAddress(created).address : 0;
        final fallbackActiveState =
            created > 0 ? bindings.sessionIsActive(created) : 0;
        AndroidFfiRuntimeProvider._log(
          '[FORENSIC_AFTER_LLB_CREATE_SESSION] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
          ' nativeSessionId=$created pointer_hex=$fallbackPointerHex'
          ' pointer_address=$fallbackPointerAddress session_active=$fallbackActiveState'
          ' isolateHash=$isolateHash thread_id=$isolateHash'
          ' session_cache_size=${_owner._nativeSessionsByModel.length}'
          ' fallback=cpu',
        );
        AndroidFfiRuntimeProvider._log(
          '[FFI_CREATE_SESSION_RETURN] returned_session_id=$created path=$modelPath gpu_layers=0 fallback=cpu',
        );
      }
      if (created <= 0) {
        AndroidFfiRuntimeProvider._log('[SESSION_CREATE_FAIL] path=$modelPath session=$created');
        final err = AndroidFfiRuntimeProvider._safeLastError(bindings, created);
        throw StateError('Native session creation failed: $err');
      }
      if (bindings.sessionIsActive(created) != 1) {
        AndroidFfiRuntimeProvider._log(
            '[SESSION_CREATE_FAIL] path=$modelPath session=$created inactive_after_create');
        final err = AndroidFfiRuntimeProvider._safeLastError(bindings, created);
        throw StateError('Native session inactive after create: $err');
      }

      _owner._nativeSessionId = created;
      _owner._nativeSessionsByModel[modelPath] = created;
      markSessionAsMostRecentlyUsed(modelPath);
      final storedPointerHex = '0x${created.toUnsigned(64).toRadixString(16)}';
      final storedPointerAddress =
          created > 0 ? Pointer<Void>.fromAddress(created).address : 0;
      AndroidFfiRuntimeProvider._log(
        '[NATIVE_SESSION_CACHE_STORE] modelId=${modelId ?? 'unknown'} model_path=$modelPath'
        ' nativeSessionId=$created pointer_hex=$storedPointerHex'
        ' pointer_address=$storedPointerAddress session_active=1'
        ' isolateHash=$isolateHash session_cache_size=${_owner._nativeSessionsByModel.length}',
      );
      AndroidFfiRuntimeProvider._log('[SESSION_CREATE_OK] path=$modelPath session=$created');
      AndroidFfiRuntimeProvider._log('[FFI_CREATE_SESSION_OK] path=$modelPath session=$created');
      AndroidFfiRuntimeProvider._log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2001 | Function: _ensureNativeSession() | AFTER exit',
      );
      return created;
    } catch (e, stackTrace) {
      AndroidFfiRuntimeProvider._log(
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
    if (sessionId == null) {
      AndroidFfiRuntimeProvider._log(
        '[NATIVE_SESSION_DOUBLE_RELEASE_SUSPECT] model_path=$modelPath reason=$reason'
        ' nativeSessionId=null pointer_hex=0x0 pointer_address=0'
        ' session_active=0 isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}'
        ' session_cache_size=${_owner._nativeSessionsByModel.length}',
      );
      return;
    }
    try {
      final pointerHex = '0x${sessionId.toUnsigned(64).toRadixString(16)}';
      final pointerAddress =
          sessionId > 0 ? Pointer<Void>.fromAddress(sessionId).address : 0;
      final activeState = bindings.sessionIsActive(sessionId);
      AndroidFfiRuntimeProvider._log(
        '[NATIVE_SESSION_RELEASE_BEGIN] model_path=$modelPath reason=$reason'
        ' nativeSessionId=$sessionId pointer_hex=$pointerHex'
        ' pointer_address=$pointerAddress session_active=$activeState'
        ' isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}'
        ' session_cache_size=${_owner._nativeSessionsByModel.length}',
      );
      AndroidFfiRuntimeProvider._log('[FFI_RELEASE] session=$sessionId path=$modelPath reason=$reason');
      bindings.releaseSession(sessionId);
    } catch (error) {
      AndroidFfiRuntimeProvider._log(
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
    AndroidFfiRuntimeProvider._log(
      '[SESSION_EVICT] strategy=lru path=$evictedModelPath session=$evictedSessionId max_active=${_owner._maxActiveNativeSessions}',
    );
    try {
      bindings.releaseSession(evictedSessionId);
    } catch (error) {
      AndroidFfiRuntimeProvider._log(
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
        AndroidFfiRuntimeProvider._log(
          '[FFI_RELEASE] session=${entry.value} path=${entry.key} reason=$reason',
        );
        bindings.releaseSession(entry.value);
      } catch (error) {
        AndroidFfiRuntimeProvider._log(
          '[FFI_RELEASE] session=${entry.value} path=${entry.key} reason=$reason failed: $error',
        );
      }
    }
    _owner._nativeSessionsByModel.clear();
    _owner._nativeSessionId = null;
  }

  void safeCancel(LlamaBridgeBindings bindings, int sessionId) {
    try {
      AndroidFfiRuntimeProvider._log('[FFI_CANCEL] session=$sessionId');
      bindings.cancelSession(sessionId);
    } catch (error) {
      AndroidFfiRuntimeProvider._log('[MODEL_EXECUTION] llb_session_cancel failed: $error');
    }
  }

  void safeResetRuntime(
    LlamaBridgeBindings bindings, {
    required String reason,
  }) {
    try {
      AndroidFfiRuntimeProvider._log('[MODEL_EXECUTION] resetting native runtime: $reason');
      final sessionId = _owner._nativeSessionId;
      if (sessionId != null) {
        AndroidFfiRuntimeProvider._log(
            '[MODEL_EXECUTION] llb_session_is_active before reset: ${bindings.sessionIsActive(sessionId)}');
        safeCancel(bindings, sessionId);
      }
      releaseAllNativeSessions(bindings, reason: reason);
    } catch (error) {
      AndroidFfiRuntimeProvider._log('[MODEL_EXECUTION] runtime reset failed: $error');
    }
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }
}
