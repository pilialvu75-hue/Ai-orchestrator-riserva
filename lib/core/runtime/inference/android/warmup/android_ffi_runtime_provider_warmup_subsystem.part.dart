part of '../../runtime_core.dart';

class _AndroidFfiWarmupSubsystem {
  _AndroidFfiWarmupSubsystem(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  Future<bool> ensureWarmup({
    required String sessionId,
    required String modelPath,
  }) async {
    _log(
      '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2110 | Function: _ensureWarmup() | BEFORE entry',
    );
    if (_owner.shouldReuseRuntimeVerification(modelPath: modelPath)) {
      _owner.verificationMonitor.update(
        RuntimeVerificationPhase.passed,
        message: 'Runtime verification reused.',
      );
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2118 | Function: _ensureWarmup() | AFTER reuse short-circuit',
      );
      return true;
    }
    if (_owner._warmupFuture == null || _owner._warmupModelPath != modelPath) {
      _owner._warmupModelPath = modelPath;
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2125 | Function: _ensureWarmup() | BEFORE assigning _runWarmup() future',
      );
      _owner._warmupFuture = runWarmup(modelPath: modelPath);
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2129 | Function: _ensureWarmup() | AFTER assigning _runWarmup() future',
      );
    }
    _log('[WARMUP] await session=$sessionId');
    try {
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2135 | Function: _ensureWarmup() | BEFORE awaiting _warmupFuture',
      );
      await _owner._warmupFuture!;
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2139 | Function: _ensureWarmup() | AFTER awaiting _warmupFuture',
      );
      _log('[WARMUP] complete session=$sessionId');
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2143 | Function: _ensureWarmup() | AFTER exit success',
      );
      return true;
    } catch (error) {
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC_EXCEPTION - File: android_ffi_runtime_provider.dart | Line: 2148 | Function: _ensureWarmup() | AFTER catch observational path exception: $error',
      );
      _owner._warmupFuture = null;
      _owner.verificationMonitor.update(
        RuntimeVerificationPhase.failed,
        message: 'Runtime warmup failed: $error',
      );
      _owner.clearRuntimeVerification();
      _log(
          '[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=warmup_failed error=$error');
      _owner._updateRuntimeStatus(
        LocalRuntimeStatus.runtimeUnavailable,
        message: 'Runtime warmup failed: $error',
      );
      _log(
        '[FFI_BRANCH] session=$sessionId name=warmup_failed_observational action=continue_to_create_session',
      );
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2166 | Function: _ensureWarmup() | AFTER exit failure_observational',
      );
      return false;
    }
  }

  Future<void> runWarmup({required String modelPath}) async {
    _log(
      '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2174 | Function: _runWarmup() | BEFORE entry',
    );
    _log('[BOOT] runtime warmup begin');
    _owner.verificationMonitor.update(
      RuntimeVerificationPhase.loading,
      message: 'Runtime warmup started.',
    );
    _owner._updateRuntimeStatus(
      LocalRuntimeStatus.loading,
      message: 'Runtime warmup in progress...',
      resetProgress: true,
    );
    if (!LlamaFfiLoader.isCurrentPlatformSupported) {
      throw StateError('Unsupported Android ABI (${LlamaFfiLoader.currentAbiName}).');
    }
    if (!_owner._ensureLibraryLoaded()) {
      throw StateError('libllama_bridge.so is missing for this Android build.');
    }
    final bindings = _owner._bindings!;
    _log('[BOOT] runtime warmup library ready');
    _owner.verificationMonitor.update(
      RuntimeVerificationPhase.running,
      message: 'Runtime warmup inference running.',
    );
    _log('[WARMUP] resolving shared native session path=$modelPath');
    final warmupSessionId = _owner._ensureNativeSession(bindings, modelPath);
    if (bindings.sessionIsActive(warmupSessionId) != 1) {
      throw StateError(
        'Warmup session inactive: ${AndroidFfiRuntimeProvider._safeLastError(bindings, warmupSessionId)}',
      );
    }
    _log('[FFI_CREATE_SESSION_OK] warmup session=$warmupSessionId');
    final tokenBufRaw = calloc<Uint8>(LlamaNativeDefaults.tokenBufferSize);
    final tokenBuf = tokenBufRaw.cast<Utf8>();
    var firstTokenSeen = false;
    final stopwatch = Stopwatch()..start();
    final warmupPromptPtr =
        AndroidFfiRuntimeProvider._warmupPrompt.toNativeUtf8(allocator: calloc);
    Pointer<Utf8>? warmupPromptPtrOrNull = warmupPromptPtr;
    void freeWarmupPromptPtr() {
      final ptr = warmupPromptPtrOrNull;
      if (ptr != null) {
        calloc.free(ptr);
        warmupPromptPtrOrNull = null;
      }
    }

    try {
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2218 | Function: _runWarmup() | BEFORE warmup startGeneration',
      );
      _log(
          '[FFI_START_GEN] entering startGeneration session=$warmupSessionId warmup=true');
      final start = bindings.startGeneration(
        warmupSessionId,
        warmupPromptPtr,
        AndroidFfiRuntimeProvider._warmupMaxTokens,
        AndroidFfiRuntimeProvider._warmupTemperature,
      );
      if (start != 0) {
        throw StateError(
          'Warmup generation start failed: ${AndroidFfiRuntimeProvider._safeLastError(bindings, warmupSessionId)}',
        );
      }
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2233 | Function: _runWarmup() | AFTER warmup startGeneration',
      );
      while (stopwatch.elapsed <
          AndroidFfiRuntimeProvider._verificationFirstTokenTimeout) {
        _log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2237 | Function: _runWarmup() | BEFORE warmup pollToken loop iteration',
        );
        _log(
            '[FFI_POLL_BEGIN] entering pollToken session=$warmupSessionId warmup=true');
        final status = bindings.pollToken(warmupSessionId, tokenBuf);
        _log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2242 | Function: _runWarmup() | AFTER warmup pollToken loop iteration status=$status',
        );
        if (status == 1) {
          final token = tokenBuf.toDartString();
          if (token.trim().isNotEmpty) {
            freeWarmupPromptPtr();
            firstTokenSeen = true;
            _log(
              '[FFI_FIRST_TOKEN] warmup session=$warmupSessionId elapsed_ms=${stopwatch.elapsedMilliseconds}',
            );
            break;
          }
        } else if (status == 2) {
          break;
        } else if (status == -1) {
          throw StateError(
            'Warmup generation failed: ${AndroidFfiRuntimeProvider._safeLastError(bindings, warmupSessionId)}',
          );
        } else if (status == -99) {
          throw StateError('Warmup generation cancelled before first token.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 24));
      }
      if (!firstTokenSeen) {
        throw StateError('FIRST_TOKEN_TIMEOUT');
      }
      _owner.verificationMonitor.update(
        RuntimeVerificationPhase.passed,
        message: 'Runtime warmup passed.',
      );
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2272 | Function: _runWarmup() | AFTER exit success',
      );
    } catch (e, stackTrace) {
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC_EXCEPTION - File: android_ffi_runtime_provider.dart | Line: 2276 | Function: _runWarmup() | BEFORE rethrow after exception: $e \n $stackTrace',
      );
      rethrow;
    } finally {
      freeWarmupPromptPtr();
      calloc.free(tokenBufRaw);
      _log('[FFI_CANCEL] warmup session=$warmupSessionId');
      bindings.cancelSession(warmupSessionId);
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2286 | Function: _runWarmup() | AFTER finally cleanup',
      );
    }
  }

  Future<T> runNativeCallWithTimeout<T>({
    required String stage,
    required Duration timeout,
    required T Function() call,
  }) {
    _log('[WARMUP] native_call stage=$stage timeout_ms=${timeout.inMilliseconds}');
    return Future<T>.sync(call).timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Native call timed out at stage=$stage after ${timeout.inSeconds}s.',
      ),
    );
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }
}
