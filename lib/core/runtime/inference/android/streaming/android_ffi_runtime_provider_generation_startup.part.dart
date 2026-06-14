part of '../../runtime_core.dart';

class _StreamFlowControlState {
  bool firstFfiInvocationAttempted = false;
  bool firstFfiInvocationCompleted = false;
}

class _GenerationStartupState {
  _GenerationStartupState({
    required this.controller,
    required this.cancellationToken,
    required this.bindings,
    required this.sessionId,
    required this.modelId,
    required this.modelPath,
    required this.isForensicSelfTest,
    required this.dartThreadId,
    required this.firstTokenDeadline,
    required this.maxTokens,
    required this.nativeSessionId,
    required this.prompt,
    required this.promptNativePtr,
    required this.freePromptNativePtr,
  });

  final StreamController<InferenceResponse> controller;
  final CancellationToken cancellationToken;
  final LlamaBridgeBindings bindings;
  final String sessionId;
  final String modelId;
  final String modelPath;
  final bool isForensicSelfTest;
  final int dartThreadId;
  final Duration firstTokenDeadline;
  final int maxTokens;
  final int nativeSessionId;
  final String prompt;
  final Pointer<Utf8> promptNativePtr;
  final void Function() freePromptNativePtr;
}
extension AndroidFfiRuntimeGenerationStartupExtension on AndroidFfiRuntimeProvider {
  Future<_GenerationStartupState?> _prepareGenerationStartup({
    required StreamController<InferenceResponse> controller,
    required InferenceRequest request,
    required CancellationToken cancellationToken,
    required _StreamFlowControlState flowState,
    required String sessionId,
    required String? modelId,
    required String? modelPath,
    required bool isForensicSelfTest,
    required int dartThreadId,
  }) async {
    final resolvedModelPath = modelPath == null || modelPath.trim().isEmpty
        ? modelPath
        : await _resolveHybridModelPath(modelPath);
    AndroidFfiRuntimeProvider._log(
      '[CONTEXT] session=$sessionId lines=${request.context.length}'
      ' system_prompt=${(request.systemPrompt ?? '').trim().isNotEmpty}',
    );
    AndroidFfiRuntimeProvider._log(
      '[MODEL_PATH] modelId=$modelId path=${resolvedModelPath ?? "(null)"}'
      ' runtimeMode=android_ffi',
    );
    if (modelPath != null &&
        resolvedModelPath != null &&
        modelPath.trim() != resolvedModelPath.trim()) {
      AndroidFfiRuntimeProvider._log( '[MODEL_PATH_RESOLVED] original=${_normalizePathForLogs(modelPath)} resolved=${_normalizePathForLogs(resolvedModelPath)}', );
    }
    if (resolvedModelPath == null ||
        resolvedModelPath.isEmpty || modelId == null ||
        modelId.trim().isEmpty) {
      _classifyFirstTokenTermination(
        flowState: flowState,
        reason: 'request_validation_missing_path_or_id',
        boundary: 'request_validation',
      );
      AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=request_validation_missing_path_or_id');
      AndroidFfiRuntimeProvider._log('[MODEL_PATH] ABORT: path or modelId is null/empty');
      AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=modelMissing reason=missing_path_or_id');
      _updateRuntimeStatus(
        LocalRuntimeStatus.modelMissing,
        message: 'No validated local model is selected.',
      );
      await _fatalEarlyExit(
        flowState: flowState,
        controller: controller,
        sessionId: sessionId,
        branch: 'request_validation_missing_path_or_id',
        reason: 'Missing local model path.',
        stage: 'request_validation',
      );
      return null;
    }
    final modelFile = File(resolvedModelPath);
    final modelExists = modelFile.existsSync();
    AndroidFfiRuntimeProvider._log('[MODEL_EXISTS] path=$resolvedModelPath exists=$modelExists');
    if (modelExists) {
      int modelSizeBytes = -1;
      bool modelReadable = false;
      try {
        modelSizeBytes = modelFile.lengthSync();
        modelReadable = modelSizeBytes > 0;
      } catch (e) {
        modelReadable = false;
      }
      AndroidFfiRuntimeProvider._log('[MODEL_SIZE] path=$resolvedModelPath size_bytes=$modelSizeBytes');
      AndroidFfiRuntimeProvider._log('[MODEL_READABLE] path=$resolvedModelPath readable=$modelReadable');
    } else {
      AndroidFfiRuntimeProvider._log('[MODEL_SIZE] path=$resolvedModelPath size_bytes=N/A (file not found)');
      AndroidFfiRuntimeProvider._log('[MODEL_READABLE] path=$resolvedModelPath readable=false (file not found)');
    }
    if (!_androidSafeModelIds.contains(modelId) && !_isImportedModelSafeForAndroid(modelId)) {
      if (_isDeveloperMode) {
        AndroidFfiRuntimeProvider._log(
          '[VALIDATION] developer_mode=true: modelId=$modelId is not in the '
          'validated set – unsupported quantization or architecture possible. '
          'Proceeding with experimental inference.',
        );
        _updateRuntimeStatus(
          LocalRuntimeStatus.runtimeUnavailable,
          message: '[DEVELOPER MODE] $modelId is experimental – compatibility not guaranteed.',
        );
        AndroidFfiRuntimeProvider._log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=developer_mode_unvalidated_model modelId=$modelId');
      } else {
        _classifyFirstTokenTermination(
          flowState: flowState,
          reason: 'unsupported_model_guard',
          boundary: 'model_guard',
        );
        AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=unsupported_model_guard');
        const unsupportedAndroidModelMessage =
            'Selected model is not enabled for Android local runtime. '
            'Use a supported GGUF model (Llama, DeepSeek, Qwen, Gemma, Phi-3, Mistral) '
            'or enable Developer Mode in Settings.';
        AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=failed reason=unsupported_model modelId=$modelId');
        _updateRuntimeStatus(
          LocalRuntimeStatus.failed,
          message: unsupportedAndroidModelMessage,
        );
        await _fatalEarlyExit(
          flowState: flowState,
          controller: controller,
          sessionId: sessionId,
          branch: 'unsupported_model_guard',
          reason: unsupportedAndroidModelMessage,
          stage: 'model_guard',
          details: 'modelId=$modelId',
        );
        return null;
      }
    }
    AndroidFfiRuntimeProvider._log('[MODEL_VALIDATION_BEGIN] session=$sessionId task=model_validation');
    String? modelValidationError;
    try {
      modelValidationError =
          AndroidFfiRuntimeProvider._validateModelFileForRuntime(resolvedModelPath);
      AndroidFfiRuntimeProvider._log('[MODEL_VALIDATION_OK] session=$sessionId task=model_validation');
    } catch (error, stackTrace) {
      _classifyFirstTokenTermination( flowState: flowState, reason: 'model_validation_failed_unexpected', boundary: 'model_validation', exception: true, );
      AndroidFfiRuntimeProvider._log('[MODEL_VALIDATION_FAIL] session=$sessionId task=model_validation error=$error');
      AndroidFfiRuntimeProvider._log('[FFI_EXCEPTION] session=$sessionId stage=model_validation stack=$stackTrace');
      await _fatalEarlyExit( flowState: flowState, controller: controller, sessionId: sessionId, branch: 'model_validation_failed_unexpected', reason: 'Model validation threw unexpectedly before first FFI call: $error', stage: 'model_validation', details: '$stackTrace', );
      return null;
    }
    if (modelValidationError != null) {
      _classifyFirstTokenTermination( flowState: flowState, reason: 'model_validation_failed', boundary: 'model_validation', );
      AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=model_validation_failed');
      AndroidFfiRuntimeProvider._log('[GGUF] validation=failed path=$resolvedModelPath reason=$modelValidationError');
      AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=failed reason=model_validation' ' path=$resolvedModelPath error=$modelValidationError');
      clearRuntimeVerification();
      _updateRuntimeStatus( LocalRuntimeStatus.failed, message: modelValidationError, );
      await _fatalEarlyExit( flowState: flowState, controller: controller, sessionId: sessionId, branch: 'model_validation_failed', reason: modelValidationError, stage: 'model_validation', );
      return null;
    }
    AndroidFfiRuntimeProvider._log('[GGUF] validation=ok path=$resolvedModelPath');
    if (!isForensicSelfTest) {
      AndroidFfiRuntimeProvider._log('[FORENSIC_BEFORE_WARMUP]');
      AndroidFfiRuntimeProvider._log( '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 689 | Function: streamInference() | BEFORE calling _ensureWarmup()', );
      final warmupReady = await _ensureWarmup( sessionId: sessionId, modelPath: resolvedModelPath, );
      AndroidFfiRuntimeProvider._log('[FORENSIC_AFTER_WARMUP]');
      AndroidFfiRuntimeProvider._log( '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 696 | Function: streamInference() | AFTER calling _ensureWarmup()', );
      if (!warmupReady) {
        AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=warmup_failed_non_blocking_continue');
      }
    } else {
      AndroidFfiRuntimeProvider._log('[WARMUP] skip session=$sessionId reason=self-test owns first token contract');
    }
    if (!_ensureLibraryLoaded()) {
      _classifyFirstTokenTermination( flowState: flowState, reason: 'library_load_failed', boundary: 'library_load', );
      AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=library_load_failed');
      AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=ffiMissing reason=library_load_failed');
      clearRuntimeVerification();
      _updateRuntimeStatus( LocalRuntimeStatus.ffiMissing, message: 'libllama_bridge.so is missing for this Android build.', );
      await _fatalEarlyExit( flowState: flowState, controller: controller, sessionId: sessionId, branch: 'library_load_failed', reason: 'Local AI runtime library (libllama_bridge.so) not found.', stage: 'library_load', );
      return null;
    }
    final bindings = _bindings!;
    _updateRuntimeStatus( LocalRuntimeStatus.loading, message: 'Loading model: $modelId', resetProgress: true, );
    await Future<void>.delayed(Duration.zero);
    AndroidFfiRuntimeProvider._logAi('creating native session...');
    AndroidFfiRuntimeProvider._log('[NATIVE_MODEL_LOAD_BEGIN] path=$resolvedModelPath modelId=$modelId' ' n_ctx=${LlamaNativeDefaults.nCtx} n_threads=${LlamaNativeDefaults.nThreads}' ' gpu_layers=${LlamaNativeDefaults.nGpuLayers}');
    int nativeSessionId;
    try {
      _setPhase(RuntimePhase.tokenizing);
      AndroidFfiRuntimeProvider._log('[FIRST_FFI_CALL_BEGIN] stage=session_create phase=$_currentFfiPhase');
      AndroidFfiRuntimeProvider._log('[FFI_PRE_CREATE_SESSION] session=$sessionId path=$resolvedModelPath');
      AndroidFfiRuntimeProvider._log( '[FORENSIC_BEFORE_CREATE_SESSION] sessionId=$sessionId modelId=$modelId modelPath=$resolvedModelPath', );
      AndroidFfiRuntimeProvider._log( '[FIRST_TOKEN_SESSION_CREATE_BEGIN] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}' ' sessionId=$sessionId modelId=$modelId', );
      flowState.firstFfiInvocationAttempted = true;
      AndroidFfiRuntimeProvider._log('[FFI_CREATE_SESSION] path=$resolvedModelPath');
      nativeSessionId = await _runNativeCallWithTimeout<int>( stage: 'session_create', timeout: AndroidFfiRuntimeProvider._modelLoadTimeout, call: () => _ensureNativeSession( bindings, resolvedModelPath, modelId: modelId, ), );
      AndroidFfiRuntimeProvider._log( '[FORENSIC_AFTER_CREATE_SESSION] nativeSessionId=$nativeSessionId', );
      AndroidFfiRuntimeProvider._log( '[FIRST_TOKEN_SESSION_CREATE_END] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}' ' sessionId=$sessionId nativeSessionId=$nativeSessionId', );
      flowState.firstFfiInvocationCompleted = true;
      AndroidFfiRuntimeProvider._log('[FFI_POST_CREATE_SESSION] session=$sessionId native_session=$nativeSessionId');
    } catch (error) {
      _classifyFirstTokenTermination( flowState: flowState, reason: error is TimeoutException ? 'session_create_timeout' : 'session_create_exception', boundary: 'session_create', exception: true, );
      AndroidFfiRuntimeProvider._log('[FFI_EXCEPTION] session=$sessionId stage=session_create error=$error');
      AndroidFfiRuntimeProvider._log('[SESSION_CREATE_FAIL] path=$resolvedModelPath exception=$error');
      AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=failed reason=session_create_exception');
      _setPhase(RuntimePhase.failed);
      _updateRuntimeStatus( error is TimeoutException ? LocalRuntimeStatus.timedOut : LocalRuntimeStatus.failed, message: error is TimeoutException ? 'Session create timed out.' : 'Session create failed: $error', );
      AndroidFfiRuntimeProvider._finishWithRuntimeError( controller, stage: 'session_create', message: 'Session create failed.', details: error.toString(), );
      return null;
    }
    AndroidFfiRuntimeProvider._log('[SESSION_CREATE_OK] session=$nativeSessionId path=$resolvedModelPath');
    AndroidFfiRuntimeProvider._log('[FFI_CREATE_SESSION_OK] session=$nativeSessionId path=$resolvedModelPath');
    final activeAfterCreate = bindings.sessionIsActive(nativeSessionId);
    AndroidFfiRuntimeProvider._log('[NATIVE_MODEL_LOAD_RESULT] llb_session_is_active after create: $activeAfterCreate');
    if (nativeSessionId <= 0 || activeAfterCreate != 1) {
      _classifyFirstTokenTermination( flowState: flowState, reason: 'session_create_invalid_or_inactive', boundary: 'session_create', );
      AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=session_create_invalid_or_inactive');
      final errMsg = AndroidFfiRuntimeProvider._safeLastError(bindings, nativeSessionId);
      AndroidFfiRuntimeProvider._log('[SESSION_CREATE_FAIL] code=$nativeSessionId error=$errMsg path=$resolvedModelPath');
      AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=failed reason=session_create_error code=$nativeSessionId');
      _updateRuntimeStatus(LocalRuntimeStatus.failed, message: errMsg);
      AndroidFfiRuntimeProvider._finishWithRuntimeError( controller, stage: 'session_create', message: 'Failed to create runtime session.', details: 'Create failed with code $nativeSessionId: $errMsg', );
      return null;
    }
    AndroidFfiRuntimeProvider._log('[NATIVE_MODEL_LOAD_SUCCESS] path=$resolvedModelPath modelId=$modelId' ' session=$nativeSessionId');
    AndroidFfiRuntimeProvider._log('[NATIVE_CONTEXT_CREATE] path=$resolvedModelPath status=ok');
    AndroidFfiRuntimeProvider._logAi('native session ready');
    final prompt = _composePrompt( request, modelId: modelId, bypassNonessentialLayers: isForensicSelfTest, );
    final promptWordEstimate = prompt .trim() .split(RegExp(r'\s+')) .where((token) => token.isNotEmpty) .length;
    if (promptWordEstimate <= 0) {
      _classifyFirstTokenTermination( flowState: flowState, reason: 'tokenizer_readiness_failed', boundary: 'tokenizer_readiness', );
      AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=tokenizer_readiness_failed');
      _updateRuntimeStatus( LocalRuntimeStatus.failed, message: 'Tokenizer readiness check failed: prompt has no tokens.', );
      AndroidFfiRuntimeProvider._finishWithRuntimeError( controller, stage: 'tokenizer_readiness', message: 'Tokenizer readiness check failed before inference.', );
      return null;
    }
    _updateRuntimeStatus( LocalRuntimeStatus.tokenizing, message: 'Tokenizing...', resetProgress: true, );
    AndroidFfiRuntimeProvider._log('[TOKENIZER] status=begin prompt_chars=${prompt.length}');
    AndroidFfiRuntimeProvider._log( '[TOKEN_COUNT] prompt_word_estimate=$promptWordEstimate prompt_chars=${prompt.length}', );
    AndroidFfiRuntimeProvider._log('[TOKENIZER_OK] prompt_word_estimate=$promptWordEstimate');
    AndroidFfiRuntimeProvider._log( '[MODEL_EXECUTION] tokenization start prompt_chars=${prompt.length} prompt_word_estimate=$promptWordEstimate', );
    AndroidFfiRuntimeProvider._log( '[CONTEXT_SIZE] session=$sessionId context_lines=${request.context.length} system_chars=${(request.systemPrompt ?? '').length} prompt_chars=${request.prompt.length} composed_prompt_chars=${prompt.length}', );
    AndroidFfiRuntimeProvider._log('[KV_CACHE] layer=native status=managed_by_llama_bridge');
    AndroidFfiRuntimeProvider._log( '[PROMPT_EVAL] stage=start prompt_chars=${prompt.length} prompt_word_estimate=$promptWordEstimate', );
    final requestedMaxTokens = isForensicSelfTest ? 4 : request.maxTokens;
    final maxTokens = requestedMaxTokens.clamp(1, AndroidFfiRuntimeProvider._safeMaxTokens);
    final effectiveTemperature = isForensicSelfTest ? 0.1 : request.temperature;
    final effectiveTopK = isForensicSelfTest ? 1 : LlamaNativeDefaults.topK;
    final effectiveTopP = isForensicSelfTest ? 0.1 : LlamaNativeDefaults.topP;
    final firstTokenDeadline = isForensicSelfTest ? AndroidFfiRuntimeProvider._verificationFirstTokenTimeout : AndroidFfiRuntimeProvider._firstTokenTimeout;
    if (request.maxTokens > AndroidFfiRuntimeProvider._safeMaxTokens) {
      AndroidFfiRuntimeProvider._log(
        '[MODEL_EXECUTION] requested max_tokens=${request.maxTokens} exceeds safe limit, clamped to $maxTokens',
      );
    }
    final loadedCheck = bindings.sessionIsActive(nativeSessionId);
    AndroidFfiRuntimeProvider._log('[MODEL_EXECUTION] llb_session_is_active before start_generation: $loadedCheck');
    if (loadedCheck != 1) {
      _classifyFirstTokenTermination( flowState: flowState, reason: 'session_inactive_before_start', boundary: 'start_generation_preflight', );
      AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=session_inactive_before_start');
      final nativeErr = AndroidFfiRuntimeProvider._safeLastError(bindings, nativeSessionId);
      _updateRuntimeStatus( LocalRuntimeStatus.failed, message: 'Session inactive (llb_session_is_active=$loadedCheck).', );
      AndroidFfiRuntimeProvider._finishWithRuntimeError( controller, stage: 'start_generation', message: 'Session is not active in the native runtime (llb_session_is_active=$loadedCheck).', details: nativeErr.isNotEmpty ? nativeErr : null, );
      return null;
    }
    AndroidFfiRuntimeProvider._log(
      '[FFI_START_GEN] entering startGeneration session=$nativeSessionId '
      'prompt_chars=${prompt.length} max_tokens=$maxTokens '
      'temperature=$effectiveTemperature',
    );
    AndroidFfiRuntimeProvider._log(
      '[GENERATION_START] session=$sessionId prompt_chars=${prompt.length}'
      ' max_tokens=$maxTokens temperature=$effectiveTemperature'
      ' n_threads=${LlamaNativeDefaults.nThreads}'
      ' n_batch=${LlamaNativeDefaults.nBatch}'
      ' n_ctx=${LlamaNativeDefaults.nCtx}'
      ' top_k=$effectiveTopK'
      ' top_p=$effectiveTopP',
    );
    AndroidFfiRuntimeProvider._logAi('starting inference...');
    final promptNativePtr = prompt.toNativeUtf8(allocator: calloc);
    Pointer<Utf8>? promptNativePtrOrNull = promptNativePtr;
    void freePromptNativePtr() {
      final ptr = promptNativePtrOrNull;
      if (ptr != null) {
        calloc.free(ptr);
        promptNativePtrOrNull = null;
      }
    }
    int startResult;
    final startupWatch = Stopwatch()..start();
    try {
      _setPhase(RuntimePhase.startingGeneration);
      final nativeHandleHex = '0x${nativeSessionId.toUnsigned(64).toRadixString(16)}';
      final nativeHandleAddress =
          nativeSessionId > 0 ? Pointer<Void>.fromAddress(nativeSessionId).address : 0;
      final activeBeforeStart = bindings.sessionIsActive(nativeSessionId);
      AndroidFfiRuntimeProvider._log(
        '[FORENSIC_BEFORE_LLB_SESSION_START_GEN] modelId=$modelId modelPath=$resolvedModelPath'
        ' sessionId=$sessionId nativeSessionId=$nativeSessionId phase=$_currentFfiPhase'
        ' pointer_hex=$nativeHandleHex pointer_address=$nativeHandleAddress'
        ' session_active=$activeBeforeStart isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}'
        ' thread_id=$dartThreadId session_cache_size=${_nativeSessionsByModel.length}'
        ' prompt_pointer_hex=0x${promptNativePtr.address.toUnsigned(64).toRadixString(16)}'
        ' prompt_pointer_address=${promptNativePtr.address}',
      );
      AndroidFfiRuntimeProvider._log('[FFI_PRE_START] session=$sessionId native_session=$nativeSessionId');
      AndroidFfiRuntimeProvider._log('[FORENSIC_BEFORE_START_GENERATION] sessionId=$sessionId nativeSessionId=$nativeSessionId');
      AndroidFfiRuntimeProvider._log(
        '[FIRST_TOKEN_START_GENERATION_BEGIN] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
        ' sessionId=$sessionId nativeSessionId=$nativeSessionId',
      );
      startResult = await _runNativeCallWithTimeout<int>(
        stage: 'start_generation',
        timeout: AndroidFfiRuntimeProvider._startGenerationTimeout,
        call: () => bindings.startGeneration(
          nativeSessionId,
          promptNativePtr,
          maxTokens,
          effectiveTemperature,
        ),
      );
      AndroidFfiRuntimeProvider._log('[FORENSIC_AFTER_START_GENERATION] sessionId=$sessionId nativeSessionId=$nativeSessionId startResult=$startResult');
      final activeAfterStart = bindings.sessionIsActive(nativeSessionId);
      AndroidFfiRuntimeProvider._log(
        '[FORENSIC_AFTER_LLB_SESSION_START_GEN] modelId=$modelId modelPath=$resolvedModelPath'
        ' sessionId=$sessionId nativeSessionId=$nativeSessionId startResult=$startResult'
        ' pointer_hex=$nativeHandleHex pointer_address=$nativeHandleAddress'
        ' session_active=$activeAfterStart isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}'
        ' thread_id=$dartThreadId session_cache_size=${_nativeSessionsByModel.length}'
        ' prompt_pointer_hex=0x${promptNativePtr.address.toUnsigned(64).toRadixString(16)}'
        ' prompt_pointer_address=${promptNativePtr.address}',
      );
      AndroidFfiRuntimeProvider._log(
        '[FIRST_TOKEN_START_GENERATION_END] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
        ' sessionId=$sessionId nativeSessionId=$nativeSessionId startResult=$startResult',
      );
      AndroidFfiRuntimeProvider._log(
        '[FFI_POST_START] session=$sessionId native_session=$nativeSessionId result=$startResult'
        ' elapsed_ms=${startupWatch.elapsedMilliseconds}',
      );
    } catch (error) {
      startupWatch.stop();
      freePromptNativePtr();
      _classifyFirstTokenTermination( flowState: flowState, reason: error is TimeoutException ? 'start_generation_timeout' : 'start_generation_exception', boundary: 'start_generation', exception: true, runtimeReset: true, );
      AndroidFfiRuntimeProvider._log('[FFI_EXCEPTION] session=$sessionId stage=start_generation error=$error');
      _setPhase(RuntimePhase.failed);
      await _safeResetRuntime(bindings, reason: 'start_generation_exception');
      _updateRuntimeStatus( error is TimeoutException ? LocalRuntimeStatus.timedOut : LocalRuntimeStatus.failed, message: error is TimeoutException ? 'Native start_generation timed out.' : 'Native start_generation failed: $error', );
      if (error is TimeoutException) {
        AndroidFfiRuntimeProvider._log( '[FFI_TIMEOUT] session=$sessionId stage=start_generation' ' timeout_ms=${AndroidFfiRuntimeProvider._startGenerationTimeout.inMilliseconds}', );
      }
      AndroidFfiRuntimeProvider._finishWithRuntimeError( controller, stage: 'start_generation', message: error is TimeoutException ? 'Native generation start timed out.' : 'Native generation start failed.', details: error.toString(), );
      return null;
    }
    startupWatch.stop();
    AndroidFfiRuntimeProvider._log('[MODEL_EXECUTION] llb_session_start_gen returned: $startResult');
    if (startupWatch.elapsed > AndroidFfiRuntimeProvider._startGenerationTimeout) {
      _classifyFirstTokenTermination( flowState: flowState, reason: 'start_generation_timeout', boundary: 'start_generation_postcheck', runtimeReset: true, );
      AndroidFfiRuntimeProvider._log( '[FFI_TIMEOUT] session=$sessionId stage=start_generation_postcheck' ' timeout_ms=${AndroidFfiRuntimeProvider._startGenerationTimeout.inMilliseconds}', );
      freePromptNativePtr();
      _safeCancel(bindings, nativeSessionId);
      _setPhase(RuntimePhase.stalled);
      await _safeResetRuntime(bindings, reason: 'start_generation_timeout');
      _updateRuntimeStatus( LocalRuntimeStatus.timedOut, message: 'Inference startup timed out after ${AndroidFfiRuntimeProvider._startGenerationTimeout.inSeconds}s.', );
      AndroidFfiRuntimeProvider._logAi('inference timeout');
      AndroidFfiRuntimeProvider._finishWithRuntimeError( controller, stage: 'start_generation', message: 'Inference startup timed out after ${AndroidFfiRuntimeProvider._startGenerationTimeout.inSeconds}s.', );
      return null;
    }
    if (startResult != 0) {
      _classifyFirstTokenTermination( flowState: flowState, reason: 'start_generation_failed_code', boundary: 'start_generation', runtimeReset: true, );
      AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=start_generation_failed_code');
      freePromptNativePtr();
      _setPhase(RuntimePhase.failed);
      final err = AndroidFfiRuntimeProvider._safeLastError(bindings, nativeSessionId);
      await _safeResetRuntime(bindings, reason: 'start_generation_failed');
      _updateRuntimeStatus(LocalRuntimeStatus.failed, message: err);
      AndroidFfiRuntimeProvider._finishWithRuntimeError( controller, stage: 'start_generation', message: 'Failed to start generation.', details: err, );
      return null;
    }
    AndroidFfiRuntimeProvider._log('[WARMUP] inference_startup_ok session=$sessionId' ' startup_ms=${startupWatch.elapsed.inMilliseconds}');
    AndroidFfiRuntimeProvider._log( '[PROMPT_EVAL] stage=ready startup_ms=${startupWatch.elapsed.inMilliseconds}', );
    return _GenerationStartupState( controller: controller, cancellationToken: cancellationToken, bindings: bindings, sessionId: sessionId, modelId: modelId, modelPath: resolvedModelPath, isForensicSelfTest: isForensicSelfTest, dartThreadId: dartThreadId, firstTokenDeadline: firstTokenDeadline, maxTokens: maxTokens, nativeSessionId: nativeSessionId, prompt: prompt, promptNativePtr: promptNativePtr, freePromptNativePtr: freePromptNativePtr, );
  }
}
