part of '../../runtime_core.dart';

const Set<String> _androidSafeModelIds = <String>{
LocalInferenceModelIds.llama1b,
LocalInferenceModelIds.gemma2b,
LocalInferenceModelIds.gemma2_2bIt,
LocalInferenceModelIds.deepSeekR1_1_5b,
LocalInferenceModelIds.qwen3_1_7b,
};

extension AndroidFfiRuntimeStreamingExtension on AndroidFfiRuntimeProvider {

  Stream<InferenceResponse> streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {

try {
AndroidFfiRuntimeProvider._log(
'[FORENSIC_PROVIDER_ENTRY] sessionId=${request.sessionId} provider=$runtimeType modelId=${request.modelId} promptLength=${request.prompt.length}',
);
AndroidFfiRuntimeProvider._log(
'[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 457 | Function: streamInference() | BEFORE entry',
);
AndroidFfiRuntimeProvider._log(
'[FORENSIC_STREAM_ENTRY] sessionId=${request.sessionId} modelId=${request.modelId} promptLength=${request.prompt.length}',
);
AndroidFfiRuntimeProvider._log(
'[STREAM_INFERENCE_ENTER] session=${request.sessionId} provider=$runtimeType hash=${hashCode.toRadixString(16)}',
);
_streamInferenceEntered = true;
AndroidFfiRuntimeProvider._log('[FORENSIC_STREAM_INFERENCE_ACTIVE] streamInferenceEntered=true sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}');
final controller = StreamController<InferenceResponse>();
AndroidFfiRuntimeProvider._log('[STREAM_CONTROLLER_CREATED] sessionId=${request.sessionId} modelId=${request.modelId}');
var firstFfiInvocationAttempted = false;
var firstFfiInvocationCompleted = false;

Future<void> fatalEarlyExit(  
    String sessionId, {  
    required String branch,  
    required String reason,  
    required String stage,  
    String? details,  
    InferenceTerminalState state = InferenceTerminalState.failed,  
  }) async {  
    AndroidFfiRuntimeProvider._log(  
      '[FFI_FATAL_EARLY_EXIT] session=$sessionId branch=$branch reason=$reason',  
    );  
    AndroidFfiRuntimeProvider._log(  
      '[FFI_BRANCH_RETURN] session=$sessionId branch=$branch reason=$reason'  
      ' first_ffi_attempted=$firstFfiInvocationAttempted first_ffi_completed=$firstFfiInvocationCompleted',  
    );  
    if (!controller.isClosed) {  
      AndroidFfiRuntimeProvider._finishWithRuntimeError(  
        controller,  
        stage: stage,  
        message: reason,  
        details: details,  
        state: state,  
      );  
    }  
  }  
  controller.onCancel = () {  
    if (!firstFfiInvocationAttempted) {  
      AndroidFfiRuntimeProvider._log(  
        '[FFI_BRANCH_RETURN] session=${request.sessionId} branch=stream_listener_cancel'  
        ' reason=stream listener detached before first FFI call',  
      );  
    }  
    AndroidFfiRuntimeProvider._log(  
      '[FFI_BRANCH] session=${request.sessionId} name=stream_listener_cancel'  
      ' first_ffi_attempted=$firstFfiInvocationAttempted',  
    );  
  };  
  AndroidFfiRuntimeProvider._log('[CANCELLATION_HANDLER_REGISTERED] sessionId=${request.sessionId}');  

  AndroidFfiRuntimeProvider._log('[ASYNC_CLOSURE_LAUNCH_BEGIN] sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()} inferenceTailHash=${(_inferenceTail ?? Future<void>.value()).hashCode}');  
  runZonedGuarded(() async {  
    AndroidFfiRuntimeProvider._log('[ASYNC_CLOSURE_ENTER] sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}');  
    AndroidFfiRuntimeProvider._log(  
      '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 508 | Function: streamInference() | BEFORE calling _runInferenceSerially()',  
    );  
    try {  
      await _concurrencyManager.runInferenceSerially(() async {  
        AndroidFfiRuntimeProvider._log('[ACTION_BODY_BEGIN] sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()} ts=${DateTime.now().microsecondsSinceEpoch}');  
        final sessionId = request.sessionId.trim().isEmpty  
            ? 'unknown'  
            : request.sessionId.trim();  
        final isVerificationSession = sessionId == AndroidFfiRuntimeProvider._forensicSelfTestSessionId;  
        final dartThreadId = AndroidFfiRuntimeProvider._currentThreadId();  
        // ── First Token Attempt Isolation: assign attempt ID ──────────────────  
        final attemptId =  
            'fta_${DateTime.now().microsecondsSinceEpoch}_${sessionId.hashCode.toRadixString(16)}';  
        _currentFirstTokenAttemptId = attemptId;  
        // Attempt telemetry captured by the unified forensic cleanup boundary.  
        var estimatedTokens = 0;  
        var pollIterations = 0;  
        DateTime? firstTokenAt;  
        // Runtime recovery classification captured even when reset happens later.  
        var runtimeNeedsReset = false;  
        String? runtimeResetReason;  
        var runtimeResetRequested = false;  

        // Termination classification is cumulative: once detected, flags stay set  
        // so ATTEMPT_END reports every condition observed across the attempt.  
        var cancellationDetected = false;  
        var exceptionDetected = false;  
        var terminationReason = 'attempt_incomplete';  
        var terminalBoundary = 'stream_scope';  
        var firstTokenAttemptClosed = false;  
        void classifyFirstTokenTermination({  
          required String reason,  
          required String boundary,  
          bool cancellation = false,  
          bool exception = false,  
          bool runtimeReset = false,  
        }) {  
          terminationReason = reason;  
          terminalBoundary = boundary;  
          cancellationDetected = cancellationDetected || cancellation;  
          exceptionDetected = exceptionDetected || exception;  
          runtimeResetRequested = runtimeResetRequested || runtimeReset;  
        }  

        void finalizeFirstTokenAttempt() {  
          if (firstTokenAttemptClosed) {  
            return;  
          }  
          firstTokenAttemptClosed = true;  
          final endAttemptId = _currentFirstTokenAttemptId ?? attemptId;  
          final preFirstTokenActiveAtEnd = _preFirstTokenActive;  
          final runtimeResetRequestedAtEnd =  
              runtimeResetRequested || runtimeNeedsReset;  
          AndroidFfiRuntimeProvider._log(  
            '[FIRST_TOKEN_ATTEMPT_END] attemptId=$endAttemptId'  
            ' sessionId=$sessionId generated_tokens=$estimatedTokens'  
            ' termination_reason=$terminationReason'  
            ' terminal_boundary=$terminalBoundary'  
            ' first_token_received=${firstTokenAt != null}'  
            ' pre_first_token_active=$preFirstTokenActiveAtEnd'  
            ' runtime_reset_requested=$runtimeResetRequestedAtEnd'  
            ' cancellation_detected=$cancellationDetected'  
            ' exception_detected=$exceptionDetected'  
            ' runtime_needs_reset=$runtimeNeedsReset'  
            ' reset_reason=${runtimeResetReason ?? 'none'}',  
          );  
          _preFirstTokenActive = false;  
          _currentFirstTokenAttemptId = null;  
        }  

        AndroidFfiRuntimeProvider._log('[ACTION_VARS_INITIALIZED] sessionId=$sessionId modelId=${request.modelId} attemptId=$attemptId dartThreadId=$dartThreadId isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()} nativeSessionId=${_nativeSessionId ?? 'null'} sessionCacheSize=${_nativeSessionsByModel.length} ts=${DateTime.now().microsecondsSinceEpoch}');  
        AndroidFfiRuntimeProvider._log(  
          '[FIRST_TOKEN_ATTEMPT_BEGIN] attemptId=$attemptId sessionId=$sessionId'  
          ' modelId=${request.modelId} is_verification=$isVerificationSession',  
        );  
        // ─────────────────────────────────────────────────────────────────────  
        AndroidFfiRuntimeProvider._log('[FFI_FLOW_ENTER] session=$sessionId thread_id=$dartThreadId');  
        _setPhase(RuntimePhase.tokenizing);  
        AndroidFfiRuntimeProvider._log(  
          '[RUNTIME_PROVIDER_BRANCH] provider=$runtimeType runtime_mode=local '  
          'branch=session_api local_request_available=true session=$sessionId',  
        );  
        AndroidFfiRuntimeProvider._log('[SESSION] begin session=$sessionId');  
        AndroidFfiRuntimeProvider._log(  
          '[DART_STREAM_LISTEN] elapsed_ms=0 thread_id=$dartThreadId token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=0 session=$sessionId',  
        );  
        if (!isVerificationSession && !_claimInferenceSlot(sessionId)) {  
          classifyFirstTokenTermination(  
            reason: 'recursive_inference_guard',  
            boundary: 'recursive_inference_guard',  
          );  
          AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=recursive_inference_guard');  
          AndroidFfiRuntimeProvider._log('[SESSION] recursive_guard_triggered session=$sessionId');  
          await fatalEarlyExit(  
            sessionId,  
            branch: 'recursive_inference_guard',  
            reason: 'Recursive inference call blocked for session $sessionId.',  
            stage: 'recursive_inference_guard',  
          );  
          AndroidFfiRuntimeProvider._log(  
            '[FFI_FLOW_EXIT] session=$sessionId first_ffi_attempted=$firstFfiInvocationAttempted'  
            ' first_ffi_completed=$firstFfiInvocationCompleted controller_closed=${controller.isClosed}',  
          );  
          return;  
        }  
        if (isVerificationSession) {  
          AndroidFfiRuntimeProvider._log(  
            '[VERIFICATION_UI_IGNORED] verification_scope=true reason=skip_activeInferenceSessions_tracking session=$sessionId',  
          );  
        }  
        try {  
          if (cancellationToken.isCancelled) {  
            classifyFirstTokenTermination(  
              reason: 'preflight_cancellation',  
              boundary: 'cancelled',  
              cancellation: true,  
            );  
            AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=preflight_cancellation');  
            await fatalEarlyExit(  
              sessionId,  
              branch: 'preflight_cancellation',  
              reason: 'Inference cancelled before first FFI call.',  
              stage: 'cancelled',  
              state: InferenceTerminalState.cancelled,  
            );  
            return;  
          }  
          final rawModelPath = request.modelPath;  
          final modelPath = rawModelPath == null || rawModelPath.trim().isEmpty  
              ? rawModelPath  
              : await _resolveHybridModelPath(rawModelPath);  
          final modelId = request.modelId;  
          AndroidFfiRuntimeProvider._log('[CONTEXT] session=$sessionId lines=${request.context.length}'  
              ' system_prompt=${(request.systemPrompt ?? '').trim().isNotEmpty}');  

          // ── MODEL PATH FORENSICS ─────────────────────────────────────────────────  
          AndroidFfiRuntimeProvider._log('[MODEL_PATH] modelId=$modelId path=${modelPath ?? "(null)"}'  
              ' runtimeMode=android_ffi');  
          if (rawModelPath != null &&  
              modelPath != null &&  
              rawModelPath.trim() != modelPath.trim()) {  
            AndroidFfiRuntimeProvider._log(  
              '[MODEL_PATH_RESOLVED] original=${_normalizePathForLogs(rawModelPath)} resolved=${_normalizePathForLogs(modelPath)}',  
            );  
          }  

          if (modelPath == null || modelPath.isEmpty || modelId == null) {  
            classifyFirstTokenTermination(  
              reason: 'request_validation_missing_path_or_id',  
              boundary: 'request_validation',  
            );  
            AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=request_validation_missing_path_or_id');  
            AndroidFfiRuntimeProvider._log('[MODEL_PATH] ABORT: path or modelId is null/empty');  
            AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=modelMissing reason=missing_path_or_id');  
            clearRuntimeVerification();  
            _updateRuntimeStatus(  
              LocalRuntimeStatus.modelMissing,  
              message: 'No validated local model is selected.',  
            );  
            await fatalEarlyExit(  
              sessionId,  
              branch: 'request_validation_missing_path_or_id',  
              reason: 'Missing local model path.',  
              stage: 'request_validation',  
            );  
            return;  
          }  

          // Log file existence / size / readability before any guard.  
          final modelFile = File(modelPath);  
          final modelExists = modelFile.existsSync();  
          AndroidFfiRuntimeProvider._log('[MODEL_EXISTS] path=$modelPath exists=$modelExists');  
          if (modelExists) {  
            int modelSizeBytes = -1;  
            bool modelReadable = false;  
            try {  
              modelSizeBytes = modelFile.lengthSync();  
              modelReadable = modelSizeBytes > 0;  
            } catch (e) {  
              modelReadable = false;  
            }  
            AndroidFfiRuntimeProvider._log('[MODEL_SIZE] path=$modelPath size_bytes=$modelSizeBytes');  
            AndroidFfiRuntimeProvider._log('[MODEL_READABLE] path=$modelPath readable=$modelReadable');  
          } else {  
            AndroidFfiRuntimeProvider._log('[MODEL_SIZE] path=$modelPath size_bytes=N/A (file not found)');  
            AndroidFfiRuntimeProvider._log('[MODEL_READABLE] path=$modelPath readable=false (file not found)');  
          }  

          if (!_androidSafeModelIds.contains(modelId)) {  
            if (_isDeveloperMode) {  
              // Developer mode: warn but allow the run to proceed.  
              AndroidFfiRuntimeProvider._log(  
                '[VALIDATION] developer_mode=true: modelId=$modelId is not in the '  
                'validated set – unsupported quantization or architecture possible. '  
                'Proceeding with experimental inference.',  
              );  
              _updateRuntimeStatus(  
                LocalRuntimeStatus.runtimeUnavailable,  
                message:  
                    '[DEVELOPER MODE] $modelId is experimental – compatibility not guaranteed.',  
              );  
              AndroidFfiRuntimeProvider._log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=developer_mode_unvalidated_model modelId=$modelId');  
            } else {  
              classifyFirstTokenTermination(  
                reason: 'unsupported_model_guard',  
                boundary: 'model_guard',  
              );  
              AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=unsupported_model_guard');  
              clearRuntimeVerification();  
              const unsupportedAndroidModelMessage =  
                  'Selected model is not enabled for Android local runtime. '  
                  'Use DeepSeek-R1-Distill-Qwen-1.5B, Qwen3-1.7B, '  
                  'gemma-2-2b-it, llama_1b, or gemma_2b.';  
              AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=failed reason=unsupported_model modelId=$modelId');  
              _updateRuntimeStatus(  
                LocalRuntimeStatus.failed,  
                message: unsupportedAndroidModelMessage,  
              );  
              await fatalEarlyExit(  
                sessionId,  
                branch: 'unsupported_model_guard',  
                reason: unsupportedAndroidModelMessage,  
                stage: 'model_guard',  
                details: 'modelId=$modelId',  
              );  
              return;  
            }  
          }  

          // Model file validation runs synchronously on the current isolate.  
          AndroidFfiRuntimeProvider._log('[MODEL_VALIDATION_BEGIN] session=$sessionId task=model_validation');  
          String? modelValidationError;  
          try {  
            modelValidationError = AndroidFfiRuntimeProvider._validateModelFileForRuntime(modelPath);  
            AndroidFfiRuntimeProvider._log('[MODEL_VALIDATION_OK] session=$sessionId task=model_validation');  
          } catch (error, stackTrace) {  
            classifyFirstTokenTermination(  
              reason: 'model_validation_failed_unexpected',  
              boundary: 'model_validation',  
              exception: true,  
            );  
            AndroidFfiRuntimeProvider._log('[MODEL_VALIDATION_FAIL] session=$sessionId task=model_validation error=$error');  
            AndroidFfiRuntimeProvider._log('[FFI_EXCEPTION] session=$sessionId stage=model_validation stack=$stackTrace');  
            await fatalEarlyExit(  
              sessionId,  
              branch: 'model_validation_failed_unexpected',  
              reason: 'Model validation threw unexpectedly before first FFI call: $error',  
              stage: 'model_validation',  
              details: '$stackTrace',  
            );  
            return;  
          }  
          if (modelValidationError != null) {  
            classifyFirstTokenTermination(  
              reason: 'model_validation_failed',  
              boundary: 'model_validation',  
            );  
            AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=model_validation_failed');  
            AndroidFfiRuntimeProvider._log('[GGUF] validation=failed path=$modelPath reason=$modelValidationError');  
            AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=failed reason=model_validation'  
                ' path=$modelPath error=$modelValidationError');  
            clearRuntimeVerification();  
            _updateRuntimeStatus(  
              LocalRuntimeStatus.failed,  
              message: modelValidationError,  
            );  
            await fatalEarlyExit(  
              sessionId,  
              branch: 'model_validation_failed',  
              reason: modelValidationError,  
              stage: 'model_validation',  
            );  
            return;  
          }  
          AndroidFfiRuntimeProvider._log('[GGUF] validation=ok path=$modelPath');  

          final isForensicSelfTest =  
              request.sessionId.trim() == AndroidFfiRuntimeProvider._forensicSelfTestSessionId;  
          if (!isForensicSelfTest) {  
            AndroidFfiRuntimeProvider._log('[FORENSIC_BEFORE_WARMUP]');  
            AndroidFfiRuntimeProvider._log(  
              '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 689 | Function: streamInference() | BEFORE calling _ensureWarmup()',  
            );  
            final warmupReady = await _ensureWarmup(  
              sessionId: sessionId,  
              modelPath: modelPath,  
            );  
            AndroidFfiRuntimeProvider._log('[FORENSIC_AFTER_WARMUP]');  
            AndroidFfiRuntimeProvider._log(  
              '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 696 | Function: streamInference() | AFTER calling _ensureWarmup()',  
            );  
            if (!warmupReady) {  
              AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=warmup_failed_non_blocking_continue');  
            }  
          } else {  
            AndroidFfiRuntimeProvider._log('[WARMUP] skip session=$sessionId reason=self-test owns first token contract');  
          }  

          if (!_ensureLibraryLoaded()) {  
            classifyFirstTokenTermination(  
              reason: 'library_load_failed',  
              boundary: 'library_load',  
            );  
            AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=library_load_failed');  
            AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=ffiMissing reason=library_load_failed');  
            clearRuntimeVerification();  
            _updateRuntimeStatus(  
              LocalRuntimeStatus.ffiMissing,  
              message:  
                  'libllama_bridge.so is missing for this Android build.',  
            );  
            await fatalEarlyExit(  
              sessionId,  
              branch: 'library_load_failed',  
              reason: 'Local AI runtime library (libllama_bridge.so) not found.',  
              stage: 'library_load',  
            );  
            return;  
          }  

          final bindings = _bindings!;  

          // ── Step 1: Create/validate native session ───────────────────────────────  
          _updateRuntimeStatus(LocalRuntimeStatus.loading,  
              message: 'Loading model: $modelId', resetProgress: true);  
          // Let UI observers process the loading state before the blocking FFI call.  
          await Future<void>.delayed(Duration.zero);  
          AndroidFfiRuntimeProvider._logAi('creating native session...');  
          AndroidFfiRuntimeProvider._log('[NATIVE_MODEL_LOAD_BEGIN] path=$modelPath modelId=$modelId'  
              ' n_ctx=${LlamaNativeDefaults.nCtx} n_threads=${LlamaNativeDefaults.nThreads}'  
              ' gpu_layers=${LlamaNativeDefaults.nGpuLayers}');  

          int nativeSessionId;  
          try {  
            _setPhase(RuntimePhase.tokenizing);  
            AndroidFfiRuntimeProvider._log('[FIRST_FFI_CALL_BEGIN] stage=session_create phase=$_currentFfiPhase');  
            AndroidFfiRuntimeProvider._log('[FFI_PRE_CREATE_SESSION] session=$sessionId path=$modelPath');  
            AndroidFfiRuntimeProvider._log(  
              '[FORENSIC_BEFORE_CREATE_SESSION] sessionId=$sessionId modelId=$modelId modelPath=$modelPath',  
            );  
            AndroidFfiRuntimeProvider._log(  
              '[FIRST_TOKEN_SESSION_CREATE_BEGIN] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'  
              ' sessionId=$sessionId modelId=$modelId',  
            );  
            // This flag marks the first native entry point for this inference flow.  
            firstFfiInvocationAttempted = true;  
            AndroidFfiRuntimeProvider._log('[FFI_CREATE_SESSION] path=$modelPath');  
            nativeSessionId = await _runNativeCallWithTimeout<int>(  
              stage: 'session_create',  
              timeout: AndroidFfiRuntimeProvider._modelLoadTimeout,  
              call: () => _ensureNativeSession(  
                bindings,  
                modelPath,  
                modelId: modelId,  
              ),  
            );  
            AndroidFfiRuntimeProvider._log(  
              '[FORENSIC_AFTER_CREATE_SESSION] nativeSessionId=$nativeSessionId',  
            );  
            AndroidFfiRuntimeProvider._log(  
              '[FIRST_TOKEN_SESSION_CREATE_END] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'  
              ' sessionId=$sessionId nativeSessionId=$nativeSessionId',  
            );  
            firstFfiInvocationCompleted = true;  
            AndroidFfiRuntimeProvider._log('[FFI_POST_CREATE_SESSION] session=$sessionId native_session=$nativeSessionId');  
          } catch (error) {  
            classifyFirstTokenTermination(  
              reason: error is TimeoutException  
                  ? 'session_create_timeout'  
                  : 'session_create_exception',  
              boundary: 'session_create',  
              exception: true,  
            );  
            AndroidFfiRuntimeProvider._log('[FFI_EXCEPTION] session=$sessionId stage=session_create error=$error');  
            AndroidFfiRuntimeProvider._log('[SESSION_CREATE_FAIL] path=$modelPath exception=$error');  
            AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=failed reason=session_create_exception');  
            clearRuntimeVerification();  
            _updateRuntimeStatus(  
              error is TimeoutException  
                  ? LocalRuntimeStatus.timedOut  
                  : LocalRuntimeStatus.failed,  
              message: error is TimeoutException  
                  ? 'Session create timed out.'  
                  : 'Session create failed: $error',  
            );  
            AndroidFfiRuntimeProvider._finishWithRuntimeError(  
              controller,  
              stage: 'session_create',  
              message: 'Session create failed.',  
              details: error.toString(),  
            );  
            return;  
          }  
          AndroidFfiRuntimeProvider._log('[SESSION_CREATE_OK] session=$nativeSessionId path=$modelPath');  
          AndroidFfiRuntimeProvider._log('[FFI_CREATE_SESSION_OK] session=$nativeSessionId path=$modelPath');  
          final activeAfterCreate = bindings.sessionIsActive(nativeSessionId);  
          AndroidFfiRuntimeProvider._log('[NATIVE_MODEL_LOAD_RESULT] llb_session_is_active after create: $activeAfterCreate');  

          if (nativeSessionId <= 0 || activeAfterCreate != 1) {  
            classifyFirstTokenTermination(  
              reason: 'session_create_invalid_or_inactive',  
              boundary: 'session_create',  
            );  
            AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=session_create_invalid_or_inactive');  
            final errMsg = AndroidFfiRuntimeProvider._safeLastError(bindings, nativeSessionId);  
            AndroidFfiRuntimeProvider._log('[SESSION_CREATE_FAIL] code=$nativeSessionId error=$errMsg path=$modelPath');  
            AndroidFfiRuntimeProvider._log('[TERMINAL_STATE] state=failed reason=session_create_error code=$nativeSessionId');  
            clearRuntimeVerification();  
            _updateRuntimeStatus(LocalRuntimeStatus.failed, message: errMsg);  
            AndroidFfiRuntimeProvider._finishWithRuntimeError(  
              controller,  
              stage: 'session_create',  
              message: 'Failed to create runtime session.',  
              details: 'Create failed with code $nativeSessionId: $errMsg',  
            );  
            return;  
          }  
          AndroidFfiRuntimeProvider._log('[NATIVE_MODEL_LOAD_SUCCESS] path=$modelPath modelId=$modelId'  
              ' session=$nativeSessionId');  
          AndroidFfiRuntimeProvider._log('[NATIVE_CONTEXT_CREATE] path=$modelPath status=ok');  
          AndroidFfiRuntimeProvider._logAi('native session ready');  

          // ── Step 2: Start generation ─────────────────────────────────────────────  
          final prompt = _composePrompt(  
            request,  
            modelId: modelId,  
            bypassNonessentialLayers: isForensicSelfTest,  
          );  
          final promptWordEstimate = prompt  
              .trim()  
              .split(RegExp(r'\s+'))  
              .where((token) => token.isNotEmpty)  
              .length;  
          if (promptWordEstimate <= 0) {  
            classifyFirstTokenTermination(  
              reason: 'tokenizer_readiness_failed',  
              boundary: 'tokenizer_readiness',  
            );  
            AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=tokenizer_readiness_failed');  
            clearRuntimeVerification();  
            _updateRuntimeStatus(  
              LocalRuntimeStatus.failed,  
              message: 'Tokenizer readiness check failed: prompt has no tokens.',  
            );  
            AndroidFfiRuntimeProvider._finishWithRuntimeError(  
              controller,  
              stage: 'tokenizer_readiness',  
              message: 'Tokenizer readiness check failed before inference.',  
            );  
            return;  
          }  
          _updateRuntimeStatus(  
            LocalRuntimeStatus.tokenizing,  
            message: 'Tokenizing...',  
            resetProgress: true,  
          );  
          AndroidFfiRuntimeProvider._log('[TOKENIZER] status=begin prompt_chars=${prompt.length}');  
          AndroidFfiRuntimeProvider._log(  
            '[TOKEN_COUNT] prompt_word_estimate=$promptWordEstimate prompt_chars=${prompt.length}',  
          );  
          AndroidFfiRuntimeProvider._log('[TOKENIZER_OK] prompt_word_estimate=$promptWordEstimate');  
          AndroidFfiRuntimeProvider._log(  
            '[MODEL_EXECUTION] tokenization start prompt_chars=${prompt.length} prompt_word_estimate=$promptWordEstimate',  
          );  
          AndroidFfiRuntimeProvider._log(  
            '[CONTEXT_SIZE] session=$sessionId context_lines=${request.context.length} system_chars=${(request.systemPrompt ?? '').length} prompt_chars=${request.prompt.length} composed_prompt_chars=${prompt.length}',  
          );  
          AndroidFfiRuntimeProvider._log('[KV_CACHE] layer=native status=managed_by_llama_bridge');  
          AndroidFfiRuntimeProvider._log(  
            '[PROMPT_EVAL] stage=start prompt_chars=${prompt.length} prompt_word_estimate=$promptWordEstimate',  
          );  
          final requestedMaxTokens = isForensicSelfTest ? 4 : request.maxTokens;  
          final maxTokens = requestedMaxTokens.clamp(1, AndroidFfiRuntimeProvider._safeMaxTokens);  
          final effectiveTemperature = isForensicSelfTest ? 0.1 : request.temperature;  
          final effectiveTopK = isForensicSelfTest ? 1 : LlamaNativeDefaults.topK;  
          final effectiveTopP = isForensicSelfTest ? 0.1 : LlamaNativeDefaults.topP;  
          final firstTokenDeadline =  
              isForensicSelfTest ? AndroidFfiRuntimeProvider._verificationFirstTokenTimeout : AndroidFfiRuntimeProvider._firstTokenTimeout;  
          if (request.maxTokens > AndroidFfiRuntimeProvider._safeMaxTokens) {  
            AndroidFfiRuntimeProvider._log(  
              '[MODEL_EXECUTION] requested max_tokens=${request.maxTokens} exceeds safe limit; clamped to $maxTokens',  
            );  
          }  

          // Verify that the native session is active before starting generation.  
          final loadedCheck = bindings.sessionIsActive(nativeSessionId);  
          AndroidFfiRuntimeProvider._log('[MODEL_EXECUTION] llb_session_is_active before start_generation: $loadedCheck');  
          if (loadedCheck != 1) {  
            classifyFirstTokenTermination(  
              reason: 'session_inactive_before_start',  
              boundary: 'start_generation_preflight',  
            );  
            AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=session_inactive_before_start');  
            clearRuntimeVerification();  
            final nativeErr = AndroidFfiRuntimeProvider._safeLastError(bindings, nativeSessionId);  
            _updateRuntimeStatus(  
              LocalRuntimeStatus.failed,  
              message: 'Session inactive (llb_session_is_active=$loadedCheck).',  
            );  
            AndroidFfiRuntimeProvider._finishWithRuntimeError(  
              controller,  
              stage: 'start_generation',  
              message:  
                  'Session is not active in the native runtime (llb_session_is_active=$loadedCheck).',  
              details: nativeErr.isNotEmpty ? nativeErr : null,  
            );  
            return;  
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

          // Allocate the prompt pointer here and keep it alive until the first  
          // token is received from pollToken.  
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
            final nativeHandleHex =  
                '0x${nativeSessionId.toUnsigned(64).toRadixString(16)}';  
            final nativeHandleAddress =  
                nativeSessionId > 0 ? Pointer<Void>.fromAddress(nativeSessionId).address : 0;  
            final activeBeforeStart = bindings.sessionIsActive(nativeSessionId);  
            AndroidFfiRuntimeProvider._log(  
              '[FORENSIC_BEFORE_LLB_SESSION_START_GEN] modelId=$modelId modelPath=$modelPath'  
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
              '[FORENSIC_AFTER_LLB_SESSION_START_GEN] modelId=$modelId modelPath=$modelPath'  
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
            classifyFirstTokenTermination(  
              reason: error is TimeoutException  
                  ? 'start_generation_timeout'  
                  : 'start_generation_exception',  
              boundary: 'start_generation',  
              exception: true,  
              runtimeReset: true,  
            );  
            AndroidFfiRuntimeProvider._log('[FFI_EXCEPTION] session=$sessionId stage=start_generation error=$error');  
            clearRuntimeVerification();  
            _setPhase(RuntimePhase.failed);  
            _safeResetRuntime(bindings, reason: 'start_generation_exception');  
            _updateRuntimeStatus(  
              error is TimeoutException  
                  ? LocalRuntimeStatus.timedOut  
                  : LocalRuntimeStatus.failed,  
              message: error is TimeoutException  
                  ? 'Native start_generation timed out.'  
                  : 'Native start_generation failed: $error',  
            );  
            if (error is TimeoutException) {  
              AndroidFfiRuntimeProvider._log(  
                '[FFI_TIMEOUT] session=$sessionId stage=start_generation'  
                ' timeout_ms=${AndroidFfiRuntimeProvider._startGenerationTimeout.inMilliseconds}',  
              );  
            }  
            AndroidFfiRuntimeProvider._finishWithRuntimeError(  
              controller,  
              stage: 'start_generation',  
              message: error is TimeoutException  
                  ? 'Native generation start timed out.'  
                  : 'Native generation start failed.',  
              details: error.toString(),  
            );  
            return;  
          }  
          startupWatch.stop();  
          AndroidFfiRuntimeProvider._log('[MODEL_EXECUTION] llb_session_start_gen returned: $startResult');  

          if (startupWatch.elapsed > AndroidFfiRuntimeProvider._startGenerationTimeout) {  
            classifyFirstTokenTermination(  
              reason: 'start_generation_timeout',  
              boundary: 'start_generation_postcheck',  
              runtimeReset: true,  
            );  
            AndroidFfiRuntimeProvider._log(  
              '[FFI_TIMEOUT] session=$sessionId stage=start_generation_postcheck'  
              ' timeout_ms=${AndroidFfiRuntimeProvider._startGenerationTimeout.inMilliseconds}',  
            );  
            freePromptNativePtr();  
            _safeCancel(bindings, nativeSessionId);  
            clearRuntimeVerification();  
            _setPhase(RuntimePhase.stalled);  
            _safeResetRuntime(bindings, reason: 'start_generation_timeout');  
            _updateRuntimeStatus(  
              LocalRuntimeStatus.timedOut,  
              message:  
                  'Inference startup timed out after ${AndroidFfiRuntimeProvider._startGenerationTimeout.inSeconds}s.',  
            );  
            AndroidFfiRuntimeProvider._logAi('inference timeout');  
            AndroidFfiRuntimeProvider._finishWithRuntimeError(  
              controller,  
              stage: 'start_generation',  
              message:  
                  'Inference startup timed out after ${AndroidFfiRuntimeProvider._startGenerationTimeout.inSeconds}s.',  
            );  
            return;  
          }  

          if (startResult != 0) {  
            classifyFirstTokenTermination(  
              reason: 'start_generation_failed_code',  
              boundary: 'start_generation',  
              runtimeReset: true,  
            );  
            AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=start_generation_failed_code');  
            freePromptNativePtr();  
            clearRuntimeVerification();  
            _setPhase(RuntimePhase.failed);  
            final err = AndroidFfiRuntimeProvider._safeLastError(bindings, nativeSessionId);  
            _safeResetRuntime(bindings, reason: 'start_generation_failed');  
            _updateRuntimeStatus(LocalRuntimeStatus.failed, message: err);  
            AndroidFfiRuntimeProvider._finishWithRuntimeError(  
              controller,  
              stage: 'start_generation',  
              message: 'Failed to start generation.',  
              details: err,  
            );  
            return;  
          }  
          AndroidFfiRuntimeProvider._log('[WARMUP] inference_startup_ok session=$sessionId'  
              ' startup_ms=${startupWatch.elapsed.inMilliseconds}');  
          AndroidFfiRuntimeProvider._log(  
            '[PROMPT_EVAL] stage=ready startup_ms=${startupWatch.elapsed.inMilliseconds}',  
          );  

          cancellationToken.onCancel(() => _safeCancel(bindings, nativeSessionId));  

          // ── Step 3: Poll for tokens ──────────────────────────────────────────────  
          _setPhase(RuntimePhase.waitingFirstToken);  
          final tokenBufRaw = calloc<Uint8>(LlamaNativeDefaults.tokenBufferSize);  
          final tokenBuf = tokenBufRaw.cast<Utf8>();  
          var repeatedTokenCount = 0;  
          var consecutiveInvalidTokens = 0;  
          String? lastPiece;  
          final fullText = StringBuffer();  
          final startedAt = DateTime.now();  
          var lastTokenProgressAt = startedAt;  
          var lastNativeActivityAt = startedAt;  
          var consecutiveIdlePolls = 0;  
          _updateRuntimeStatus(  
            LocalRuntimeStatus.inferencing,  
            message: 'Generating',  
            tokensGenerated: 0,  
            elapsed: Duration.zero,  
            startedAt: startedAt,  
          );  
          AndroidFfiRuntimeProvider._logAi('streaming callback active');  
          AndroidFfiRuntimeProvider._log('[STREAM_ADD] event=generation_started session=$sessionId');  
          AndroidFfiRuntimeProvider._log('[TOKEN_STREAM] loop start max_tokens=$maxTokens');  
          AndroidFfiRuntimeProvider._log('[TOKEN_LOOP] phase=start max_tokens=$maxTokens');  
          AndroidFfiRuntimeProvider._log('[FFI_PRE_POLL] session=$sessionId native_session=$nativeSessionId');  
          AndroidFfiRuntimeProvider._log('[FFI_POLL_BEGIN] session=$nativeSessionId');  
          _preFirstTokenActive = true;  
          _setPhase(RuntimePhase.waitingFirstToken);  
          var firstPollBoundaryLogged = false;  
          var firstPollBoundaryFinished = false;  
          AndroidFfiRuntimeProvider._log(  
            '[FIRST_TOKEN_POLL_LOOP_BEGIN] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'  
            ' sessionId=$sessionId nativeSessionId=$nativeSessionId phase=$_currentFfiPhase'  
            ' pre_first_token_active=true max_tokens=$maxTokens',  
          );  

          try {  
            while (true) {  
              pollIterations++;  
              if (pollIterations % 50 == 0) {  
                await Future<void>.delayed(const Duration(milliseconds: 1));  
              }  
              final now = DateTime.now();  
              final elapsed = now.difference(startedAt);  
              final sinceFirstToken =  
                  firstTokenAt == null ? null : now.difference(firstTokenAt);  
              final sinceLastTokenProgress = now.difference(lastTokenProgressAt);  
              _throttledLoopLog(  
                '[TOKEN_STREAM] poll iteration=$pollIterations tokens=$estimatedTokens elapsed_ms=${elapsed.inMilliseconds}'  
                ' idle_ms=${sinceLastTokenProgress.inMilliseconds} idle_polls=$consecutiveIdlePolls phase=$_currentFfiPhase',  
              );  
              _throttledLoopLog(  
                '[TOKEN_LOOP] iteration=$pollIterations tokens=$estimatedTokens elapsed_ms=${elapsed.inMilliseconds}',  
              );  
              _throttledLoopLog(  
                '[GENERATION_STEP] iteration=$pollIterations elapsed_ms=${elapsed.inMilliseconds}'  
                ' generated_tokens=$estimatedTokens',  
              );  
              _throttledLoopLog(  
                '[GENERATION_ALIVE] iteration=$pollIterations elapsed_ms=${elapsed.inMilliseconds} first_token=${firstTokenAt != null}',  
              );  
              if (firstTokenAt == null && pollIterations % 25 == 0) {  
                AndroidFfiRuntimeProvider._log(  
                  '[FIRST_TOKEN_WAIT] iteration=$pollIterations waited_ms=${elapsed.inMilliseconds}',  
                );  
              }  
              if (cancellationToken.isCancelled || controller.isClosed) {  
                classifyFirstTokenTermination(  
                  reason: 'poll_cancellation',  
                  boundary: 'poll_loop',  
                  cancellation: true,  
                );  
                _safeCancel(bindings, nativeSessionId);  
                clearRuntimeVerification();  
                AndroidFfiRuntimeProvider._log(  
                  '[TERMINAL_STATE] state=cancelled generated_tokens=$estimatedTokens'  
                  ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}',  
                );  
                if (!controller.isClosed) {  
                  AndroidFfiRuntimeProvider._finishWithRuntimeError(  
                    controller,  
                    stage: 'cancelled',  
                    message: 'Inference cancelled.',  
                    state: InferenceTerminalState.cancelled,  
                  );  
                }  
                _updateRuntimeStatus(  
                  LocalRuntimeStatus.runtimeUnavailable,  
                  message: 'Cancelled',  
                  tokensGenerated: estimatedTokens,  
                  elapsed: DateTime.now().difference(startedAt),  
                );  
                AndroidFfiRuntimeProvider._log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=pre_poll_cancellation');  
                break;  
              }  

              if (elapsed > AndroidFfiRuntimeProvider._generationTimeout) {  
                classifyFirstTokenTermination(  
                  reason: firstTokenAt == null  
                      ? 'generation_timeout_no_first_token'  
                      : 'generation_timeout',  
                  boundary: 'poll_loop',  
                  runtimeReset: true,  
                );  
                _setPhase(RuntimePhase.stalled);  
                AndroidFfiRuntimeProvider._log(  
                  '[FFI_TIMEOUT] session=$sessionId stage=generation_timeout'  
                  ' timeout_ms=${AndroidFfiRuntimeProvider._generationTimeout.inMilliseconds}',  
                );  
                _safeCancel(bindings, nativeSessionId);  
                clearRuntimeVerification();  
                _setPhase(RuntimePhase.failed);  
                runtimeNeedsReset = true;  
                runtimeResetReason = 'generation_timeout';  
                if (firstTokenAt == null) {  
                  AndroidFfiRuntimeProvider._log(  
                    '[FIRST_TOKEN_FAILURE] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'  
                    ' sessionId=$sessionId reason=generation_timeout_no_first_token'  
                    ' elapsed_ms=${elapsed.inMilliseconds}'  
                    ' timeout_ms=${AndroidFfiRuntimeProvider._generationTimeout.inMilliseconds}'  
                    ' poll_iterations=$pollIterations',  
                  );  
                }  
                AndroidFfiRuntimeProvider._log(  
                  '[TERMINAL_STATE] state=timedOut reason=generation_timeout'  
                  ' generated_tokens=$estimatedTokens elapsed_ms=${elapsed.inMilliseconds}',  
                );  
                _updateRuntimeStatus(  
                  LocalRuntimeStatus.timedOut,  
                  message: 'Timed out',  
                  tokensGenerated: estimatedTokens,  
                  elapsed: elapsed,  
                  startedAt: startedAt,  
                );  
                AndroidFfiRuntimeProvider._logAi('inference timeout');  
                final partialText = _flushStructuralTemplateOutput(fullText);  
                await AndroidFfiRuntimeProvider._finishWithPartialOrRuntimeError(  
                  controller,  
                  stage: 'timeout',  
                  message: 'Local generation timed out.',  
                  modelId: modelId,  
                  fullText: partialText,  
                  tokensGenerated: estimatedTokens,  
                  notice:  
                      'Local model timed out after ${elapsed.inSeconds}s. Returning partial response.',  
                  partialTerminalState: InferenceTerminalState.timeout,  
                );  
                break;  
              }  
              final firstTokenWaitElapsed = now.difference(lastNativeActivityAt);  
              if (firstTokenAt == null &&  
                  firstTokenWaitElapsed.inMilliseconds >  
                      firstTokenDeadline.inMilliseconds) {  
                classifyFirstTokenTermination(  
                  reason: 'first_token_watchdog',  
                  boundary: 'poll_loop',  
                  runtimeReset: true,  
                );  
                _setPhase(RuntimePhase.stalled);  
                AndroidFfiRuntimeProvider._log(  
                  '[FFI_TIMEOUT] session=$sessionId stage=first_token_watchdog'  
                  ' timeout_ms=${firstTokenDeadline.inMilliseconds}',  
                );  
                _safeCancel(bindings, nativeSessionId);  
                clearRuntimeVerification();  
                runtimeNeedsReset = true;  
                runtimeResetReason = 'first_token_watchdog';  
                AndroidFfiRuntimeProvider._log(  
                  '[STREAM_TIMEOUT] reason=no_first_token elapsed_ms=${elapsed.inMilliseconds}'  
                  ' timeout_ms=${firstTokenDeadline.inMilliseconds} session=$sessionId',  
                );  
                AndroidFfiRuntimeProvider._log(  
                  '[STALL] reason=first_token_watchdog elapsed_ms=${elapsed.inMilliseconds}'  
                  ' no_token_produced=true session=$sessionId',  
                );  
                AndroidFfiRuntimeProvider._log(  
                  '[FIRST_TOKEN_TIMEOUT] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=$pollIterations timeout_ms=${firstTokenDeadline.inMilliseconds}',  
                );  
                AndroidFfiRuntimeProvider._log(  
                  '[FIRST_TOKEN_FAILURE] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'  
                  ' sessionId=$sessionId reason=first_token_watchdog'  
                  ' elapsed_ms=${elapsed.inMilliseconds} timeout_ms=${firstTokenDeadline.inMilliseconds}'  
                  ' poll_iterations=$pollIterations pre_first_token_active=$_preFirstTokenActive',  
                );  
                AndroidFfiRuntimeProvider._log(  
                  '[TERMINAL_STATE] state=stalled reason=first_token_watchdog'  
                  ' elapsed_ms=${elapsed.inMilliseconds} no_token_produced=true',  
                );  
                _updateRuntimeStatus(  
                  LocalRuntimeStatus.stalled,  
                  message: 'Runtime stalled',  
                  tokensGenerated: estimatedTokens,  
                  elapsed: elapsed,  
                  startedAt: startedAt,  
                );  
                AndroidFfiRuntimeProvider._logAi('inference timeout');  
                AndroidFfiRuntimeProvider._finishWithRuntimeError(  
                  controller,  
                  stage: 'stalled',  
                  message: isForensicSelfTest  
                      ? 'FIRST_TOKEN_TIMEOUT'  
                      : 'Local model stalled during inference.',  
                );  
                break;  
              }  
              if (firstTokenAt != null &&  
                  sinceLastTokenProgress > AndroidFfiRuntimeProvider._noTokenProgressTimeout) {  
                classifyFirstTokenTermination(  
                  reason: 'token_progress_watchdog',  
                  boundary: 'poll_loop',  
                  runtimeReset: true,  
                );  
                _setPhase(RuntimePhase.stalled);  
                _safeCancel(bindings, nativeSessionId);  
                clearRuntimeVerification();  
                runtimeNeedsReset = true;  
                runtimeResetReason = 'token_progress_watchdog';  
                AndroidFfiRuntimeProvider._log(  
                  '[STALL] reason=token_progress_watchdog'  
                  ' generated_tokens=$estimatedTokens'  
                  ' elapsed_ms=${elapsed.inMilliseconds}'  
                  ' since_last_token_ms=${sinceLastTokenProgress.inMilliseconds}'  
                  ' session=$sessionId',  
                );  
                AndroidFfiRuntimeProvider._log(  
                  '[TERMINAL_STATE] state=stalled reason=token_progress_watchdog'  
                  ' generated_tokens=$estimatedTokens'  
                  ' elapsed_ms=${elapsed.inMilliseconds}'  
                  ' since_last_token_ms=${sinceLastTokenProgress.inMilliseconds}',  
                );
                _updateRuntimeStatus(
LocalRuntimeStatus.stalled,
message: 'Token stream stalled',
tokensGenerated: estimatedTokens,
elapsed: elapsed,
startedAt: startedAt,
);
final partialText = _flushStructuralTemplateOutput(fullText);
await AndroidFfiRuntimeProvider._finishWithPartialOrRuntimeError(
controller,
stage: 'stalled',
message: 'Token stream stalled during local inference.',
modelId: modelId,
fullText: partialText,
tokensGenerated: estimatedTokens,
notice:
'Token stream stalled after ${sinceLastTokenProgress.inSeconds}s. Returning partial response.',
partialTerminalState: InferenceTerminalState.timeout,
);
break;
}
if (_pollingController.isIdleLimitReached(consecutiveIdlePolls)) {
debugPrint(
'[TOKEN_STREAM] Hard cap reached: consecutiveIdlePolls >= ${_pollingController.maxIdlePollIterations}. Aborting loop.',
);
classifyFirstTokenTermination(
reason: 'poll_loop_watchdog',
boundary: 'poll_loop',
runtimeReset: true,
);
_setPhase(RuntimePhase.stalled);
_safeCancel(bindings, nativeSessionId);
clearRuntimeVerification();
runtimeNeedsReset = true;
runtimeResetReason = 'poll_loop_watchdog';
AndroidFfiRuntimeProvider._log(
'[STREAM_TIMEOUT] reason=poll_loop_idle idle_polls=$consecutiveIdlePolls'
' elapsed_ms=${elapsed.inMilliseconds} session=$sessionId',
);
AndroidFfiRuntimeProvider._log(
'[STALL] reason=poll_loop_watchdog'
' idle_polls=$consecutiveIdlePolls generated_tokens=$estimatedTokens'
' elapsed_ms=${elapsed.inMilliseconds} session=$sessionId',
);
AndroidFfiRuntimeProvider._log(
'[TERMINAL_STATE] state=stalled reason=poll_loop_watchdog'
' idle_polls=$consecutiveIdlePolls generated_tokens=$estimatedTokens'
' elapsed_ms=${elapsed.inMilliseconds}',
);
_updateRuntimeStatus(
LocalRuntimeStatus.stalled,
message: 'Polling loop stalled',
tokensGenerated: estimatedTokens,
elapsed: elapsed,
startedAt: startedAt,
);
final partialText = _flushStructuralTemplateOutput(fullText);
await AndroidFfiRuntimeProvider._finishWithPartialOrRuntimeError(
controller,
stage: 'poll_loop',
message: 'Token polling stalled in local runtime.',
modelId: modelId,
fullText: partialText,
tokensGenerated: estimatedTokens,
notice:
'No token progress detected in polling loop. Returning partial response.',
partialTerminalState: InferenceTerminalState.timeout,
);
break;
}

int status;  
              try {  
                _throttledLoopLog(  
                  '[FFI_POLL_BEGIN] entering pollToken session=$nativeSessionId '  
                  'iteration=$pollIterations phase=$_currentFfiPhase',  
                );  
                if (!firstPollBoundaryLogged) {  
                  firstPollBoundaryLogged = true;  
                  final pollHandleHex =  
                      '0x${nativeSessionId.toUnsigned(64).toRadixString(16)}';  
                  final pollHandleAddress = nativeSessionId > 0  
                      ? Pointer<Void>.fromAddress(nativeSessionId).address  
                      : 0;  
                  final activeBeforeFirstPoll = bindings.sessionIsActive(nativeSessionId);  
                  AndroidFfiRuntimeProvider._log(  
                    '[FORENSIC_BEFORE_FIRST_LLB_SESSION_POLL_TOKEN] modelId=$modelId modelPath=$modelPath'  
                    ' sessionId=$sessionId nativeSessionId=$nativeSessionId'  
                    ' pointer_hex=$pollHandleHex pointer_address=$pollHandleAddress'  
                    ' session_active=$activeBeforeFirstPoll isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}'  
                    ' thread_id=$dartThreadId session_cache_size=${_nativeSessionsByModel.length}'  
                    ' token_buffer_pointer_hex=0x${tokenBufRaw.address.toUnsigned(64).toRadixString(16)}'  
                    ' token_buffer_pointer_address=${tokenBufRaw.address}',  
                  );  
                }  
                AndroidFfiRuntimeProvider._log(  
                  '[FFI_CALLBACK_ENTER] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 poll_iteration=$pollIterations',  
                );  
                status = bindings.pollToken(nativeSessionId, tokenBuf);  
                if (!firstPollBoundaryFinished) {  
                  firstPollBoundaryFinished = true;  
                  final pollHandleHex =  
                      '0x${nativeSessionId.toUnsigned(64).toRadixString(16)}';  
                  final pollHandleAddress = nativeSessionId > 0  
                      ? Pointer<Void>.fromAddress(nativeSessionId).address  
                      : 0;  
                  final activeAfterFirstPoll = bindings.sessionIsActive(nativeSessionId);  
                  AndroidFfiRuntimeProvider._log(  
                    '[FORENSIC_AFTER_FIRST_LLB_SESSION_POLL_TOKEN] modelId=$modelId modelPath=$modelPath'  
                    ' sessionId=$sessionId nativeSessionId=$nativeSessionId status=$status'  
                    ' pointer_hex=$pollHandleHex pointer_address=$pollHandleAddress'  
                    ' session_active=$activeAfterFirstPoll isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}'  
                    ' thread_id=$dartThreadId session_cache_size=${_nativeSessionsByModel.length}'  
                    ' token_buffer_pointer_hex=0x${tokenBufRaw.address.toUnsigned(64).toRadixString(16)}'  
                    ' token_buffer_pointer_address=${tokenBufRaw.address}',  
                  );  
                }  
              } catch (error) {  
                classifyFirstTokenTermination(  
                  reason: 'poll_token_exception',  
                  boundary: 'poll_token',  
                  exception: true,  
                  runtimeReset: true,  
                );  
                clearRuntimeVerification();  
                runtimeNeedsReset = true;  
                runtimeResetReason = 'poll_token_exception';  
                _setPhase(RuntimePhase.failed);  
                _updateRuntimeStatus(  
                  LocalRuntimeStatus.failed,  
                  message: 'Native poll_token failed: $error',  
                );  
                AndroidFfiRuntimeProvider._finishWithRuntimeError(  
                  controller,  
                  stage: 'poll_token',  
                  message: 'Native poll_token failed.',  
                  details: error.toString(),  
                );  
                break;  
              }  
              _throttledLoopLog(  
                '[TOKEN_STREAM] poll status iteration=$pollIterations status=$status',  
              );  
              AndroidFfiRuntimeProvider._log(  
                '[FFI_CALLBACK_PAYLOAD] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 poll_iteration=$pollIterations status=$status',  
              );  

              if (status == 1) {  
                String piece;  
                try {  
                  piece = tokenBuf.toDartString();  
                } catch (error) {  
                  AndroidFfiRuntimeProvider._log('[TOKENIZER_DECODE_FAIL] stage=dart_utf8_decode error=$error');  
                  consecutiveInvalidTokens++;  
                  if (consecutiveInvalidTokens >= AndroidFfiRuntimeProvider._maxConsecutiveInvalidTokens) {  
                    classifyFirstTokenTermination(  
                      reason: 'token_decode_exception',  
                      boundary: 'token_decode',  
                      exception: true,  
                      runtimeReset: true,  
                    );  
                    _safeCancel(bindings, nativeSessionId);  
                    clearRuntimeVerification();  
                    runtimeNeedsReset = true;  
                    runtimeResetReason = 'token_decode_exception';  
                    AndroidFfiRuntimeProvider._log(  
                      '[TERMINAL_STATE] state=failed reason=token_decode_exception'  
                      ' generated_tokens=$estimatedTokens'  
                      ' error=$error',  
                    );  
                    _updateRuntimeStatus(  
                      LocalRuntimeStatus.failed,  
                      message: 'Invalid generated token stream.',  
                      tokensGenerated: estimatedTokens,  
                      elapsed: DateTime.now().difference(startedAt),  
                      startedAt: startedAt,  
                    );  
                    AndroidFfiRuntimeProvider._finishWithRuntimeError(  
                      controller,  
                      stage: 'token_decode',  
                      message: 'Invalid generated token stream.',  
                      details: error.toString(),  
                    );  
                    break;  
                  }  
                  continue;  
                }  
                final trimmedPiece = piece.trim();  
                final tokenObservedAt = DateTime.now();  
                lastNativeActivityAt = tokenObservedAt;  
                if (_shouldIgnoreToken(trimmedPiece)) {  
                  continue;  
                }  
                final sanitizedPiece = _sanitizeStructuralTemplateOutput(piece);  
                final trimmedSanitizedPiece = sanitizedPiece.trim();  
                if (trimmedSanitizedPiece.isEmpty) {  
                  continue;  
                }  
                if (_isDeveloperMode) {  
                  AndroidFfiRuntimeProvider._log('RAW_TOKEN: "${piece.replaceAll('\n', r'\n')}"');  
                  AndroidFfiRuntimeProvider._log('SANITIZED_TOKEN: "${sanitizedPiece.replaceAll('\n', r'\n')}"');  
                }  

                _resetIdleBackoff();  
                final isFirstToken = firstTokenAt == null;  
                DateTime? firstTokenTimestamp;  
                if (isFirstToken && _preFirstTokenActive) {  
                  firstTokenTimestamp =  
                      _handleFirstTokenIfNeeded(sanitizedPiece);  
                  if (firstTokenTimestamp != null) {  
                    firstTokenAt = firstTokenTimestamp;  
                  }  
                }  
                final firstTokenReceived = firstTokenTimestamp != null;  
                consecutiveInvalidTokens = 0;  
                consecutiveIdlePolls = 0;  
                lastTokenProgressAt = tokenObservedAt;  
                fullText.write(sanitizedPiece);  
                estimatedTokens++;  
                recordVerificationSuccess(  
                modelPath: modelPath,  
                source: 'first_token',  
                );  
                final streamingElapsed = DateTime.now().difference(startedAt);  
                AndroidFfiRuntimeProvider._log(  
                '[FFI_CALLBACK_PAYLOAD] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} poll_iteration=$pollIterations status=$status',  
                );  
                AndroidFfiRuntimeProvider._log(  
                '[DART_STREAM_RECEIVE] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} poll_iteration=$pollIterations subscription_alive=${!controller.isClosed}',  
                );  
                if (firstTokenReceived) {  
                freePromptNativePtr();  
                AndroidFfiRuntimeProvider._log(  
                    '[FFI_FIRST_TOKEN] session=$nativeSessionId elapsed_ms=${streamingElapsed.inMilliseconds} chars=${sanitizedPiece.length} phase=$_runtimePhase',  
                );  
                AndroidFfiRuntimeProvider._log(  
                    '[FIRST_TOKEN] elapsed_ms=${streamingElapsed.inMilliseconds}'  
                    ' token_text_length=${sanitizedPiece.length}'  
                    ' poll_iteration=$pollIterations session=$sessionId',  
                );  
                AndroidFfiRuntimeProvider._log(  
                    '[FIRST_TOKEN_REAL] elapsed_ms=${streamingElapsed.inMilliseconds}'  
                    ' thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length}'  
                    ' queue_size=-1 poll_iteration=$pollIterations'  
                    ' token="${sanitizedPiece.replaceAll('\n', r'\n')}" token_count=$estimatedTokens',  
                );  
                AndroidFfiRuntimeProvider._log(  
                    '[FIRST_TOKEN_SUCCESS] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'  
                    ' sessionId=$sessionId nativeSessionId=$nativeSessionId'  
                    ' elapsed_ms=${streamingElapsed.inMilliseconds}'  
                    ' chars=${sanitizedPiece.length} poll_iterations=$pollIterations'  
                    ' pre_first_token_active=false',  
                );  
                }  
                AndroidFfiRuntimeProvider._log(  
                '[DART_TOKEN_RECEIVED] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} queue_size=-1 poll_iteration=$pollIterations',  
                );  
                AndroidFfiRuntimeProvider._log('[FFI_TOKEN] session=$nativeSessionId chars=${sanitizedPiece.length}');  
                if (estimatedTokens % 16 == 0) {  
                AndroidFfiRuntimeProvider._log('[TOKEN_STREAM] token_count=$estimatedTokens');  
                }  
                AndroidFfiRuntimeProvider._log(  
                '[TOKEN_STREAM] piece token_index=$estimatedTokens text="${sanitizedPiece.replaceAll('\n', r'\n')}"'  
                ' total_chars=${fullText.length} since_first_token_ms=${sinceFirstToken?.inMilliseconds ?? 0}',  
                );  
                AndroidFfiRuntimeProvider._log(  
                '[TOKEN_EVAL] token_index=$estimatedTokens elapsed_ms=${streamingElapsed.inMilliseconds}',  
                );  
                AndroidFfiRuntimeProvider._log(  
                '[TOKEN_DECODE] token_index=$estimatedTokens chars=${sanitizedPiece.length}'  
                ' text="${sanitizedPiece.replaceAll('\n', r'\n')}"',  
                );  
                if (sanitizedPiece == lastPiece) {  
                repeatedTokenCount++;  
                if (repeatedTokenCount >= AndroidFfiRuntimeProvider._maxRepeatedTokenLoop) {  
                    classifyFirstTokenTermination(  
                      reason: 'repeated_token_loop',  
                      boundary: 'generation_loop',  
                      runtimeReset: true,  
                    );  
                    _safeCancel(bindings, nativeSessionId);  
                    clearRuntimeVerification();  
                    runtimeNeedsReset = true;  
                    runtimeResetReason = 'repeated_token_loop';  
                    _setPhase(RuntimePhase.failed);  
                    AndroidFfiRuntimeProvider._log(  
                      '[STREAM_LOOP] reason=repeated_token'  
                      ' count=$repeatedTokenCount token="${sanitizedPiece.replaceAll('\n', r'\n')}"'  
                      ' generated_tokens=$estimatedTokens session=$sessionId',  
                    );  
                    AndroidFfiRuntimeProvider._log(  
                      '[TERMINAL_STATE] state=failed reason=repeated_token_loop'  
                      ' generated_tokens=$estimatedTokens'  
                      ' elapsed_ms=${streamingElapsed.inMilliseconds}',  
                    );  
                    _updateRuntimeStatus(  
                      LocalRuntimeStatus.failed,  
                      message: 'Repeated-token loop detected.',  
                      tokensGenerated: estimatedTokens,  
                      elapsed: streamingElapsed,  
                      startedAt: startedAt,  
                    );  
                    AndroidFfiRuntimeProvider._finishWithRuntimeError(  
                      controller,  
                      stage: 'generation_loop',  
                      message: 'Repeated-token loop detected.',  
                      details: 'token="$sanitizedPiece"',  
                    );  
                    break;  
                }  
                } else {  
                lastPiece = sanitizedPiece;  
                repeatedTokenCount = 0;  
                }  
                _setPhase(RuntimePhase.streaming);  
                _updateRuntimeStatus(  
                LocalRuntimeStatus.streaming,  
                message: 'Streaming',  
                tokensGenerated: estimatedTokens,  
                elapsed: streamingElapsed,  
                startedAt: startedAt,  
                );  
                AndroidFfiRuntimeProvider._log(  
                '[TOKEN_EMIT] token_index=$estimatedTokens chars=${sanitizedPiece.length}'  
                ' session=$sessionId',  
                );  
                AndroidFfiRuntimeProvider._log(  
                '[DART_STREAM_RENDER] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} queue_size=-1 poll_iteration=$pollIterations subscription_alive=${!controller.isClosed}',  
                );  
                AndroidFfiRuntimeProvider._log('[STREAM_ADD] event=token session=$sessionId');  
                final flushWatch = Stopwatch()..start();  
                try {  
                if (!controller.isClosed) {  
                    _AndroidFfiRuntimeExecutionBoundary.emitTokenChunk(  
                      controller,  
                      text: sanitizedPiece,  
                      model: modelId,  
                    );  
                    if (firstTokenReceived) {  
                      AndroidFfiRuntimeProvider._log('[FORENSIC_FIRST_TOKEN] sessionId=$sessionId nativeSessionId=$nativeSessionId chars=${sanitizedPiece.length}');  
                    }  
                }  
                } catch (_) {}  
                flushWatch.stop();  
                AndroidFfiRuntimeProvider._log(  
                '[STREAM_FLUSH] event=token session=$sessionId flush_us=${flushWatch.elapsedMicroseconds}',  
                );  
              } else if (status == 2) {  
                classifyFirstTokenTermination(  
                  reason: 'completed',  
                  boundary: 'poll_loop',  
                );  
                _setPhase(RuntimePhase.completed);  
                // EOS or max-tokens: generation complete.  
                final completedElapsed = DateTime.now().difference(startedAt);  
                recordVerificationSuccess(  
                  modelPath: modelPath,  
                  source: 'eos',  
                );  
                AndroidFfiRuntimeProvider._log('[FFI_EOS] session=$nativeSessionId');  
                AndroidFfiRuntimeProvider._log(  
                  '[GENERATION_END] state=success generated_tokens=$estimatedTokens'  
                  ' elapsed_ms=${completedElapsed.inMilliseconds}',  
                );  
                AndroidFfiRuntimeProvider._log(  
                  '[FINAL_RESPONSE] eos generated_tokens=$estimatedTokens elapsed_ms=${completedElapsed.inMilliseconds}',  
                );  
                AndroidFfiRuntimeProvider._log(  
                  '[TERMINAL_STATE] state=success generated_tokens=$estimatedTokens'  
                  ' elapsed_ms=${completedElapsed.inMilliseconds}',  
                );  
                AndroidFfiRuntimeProvider._logAi('inference completed');  
                AndroidFfiRuntimeProvider._log('[STREAM_ADD] event=final_chunk session=$sessionId');  
                final flushWatch = Stopwatch()..start();  
                if (!controller.isClosed) {  
                  final sanitizedFinalText =  
                      _flushStructuralTemplateOutput(fullText);  
                  _AndroidFfiRuntimeExecutionBoundary.emitFinalChunk(  
                    controller,  
                    text: sanitizedFinalText.isEmpty ? '\u200B' : sanitizedFinalText,  
                    tokensGenerated: estimatedTokens,  
                    model: modelId,  
                  );  
                }  
                flushWatch.stop();  
                AndroidFfiRuntimeProvider._log(  
                  '[STREAM_FLUSH] event=final_chunk session=$sessionId flush_us=${flushWatch.elapsedMicroseconds}',  
                );  
                _updateRuntimeStatus(  
                  LocalRuntimeStatus.completed,  
                  message: 'Completed',  
                  tokensGenerated: estimatedTokens,  
                  elapsed: completedElapsed,  
                  startedAt: startedAt,  
                );  
                break;  
              } else if (status == -99) {  
                classifyFirstTokenTermination(  
                  reason: 'native_cancelled',  
                  boundary: 'poll_loop',  
                  cancellation: true,  
                );  
                _setPhase(RuntimePhase.cancelled);  
                AndroidFfiRuntimeProvider._log('[GENERATION_END] state=cancelled generated_tokens=$estimatedTokens');  
                AndroidFfiRuntimeProvider._log(  
                  '[TERMINAL_STATE] state=cancelled generated_tokens=$estimatedTokens'  
                  ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}',  
                );  
                clearRuntimeVerification();  
                if (!controller.isClosed) {  
                  AndroidFfiRuntimeProvider._finishWithRuntimeError(  
                    controller,  
                    stage: 'cancelled',  
                    message: 'Inference cancelled.',  
                    state: InferenceTerminalState.cancelled,  
                  );  
                }  
                AndroidFfiRuntimeProvider._log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=native_cancelled');  
                _updateRuntimeStatus(  
                  LocalRuntimeStatus.runtimeUnavailable,  
                  tokensGenerated: estimatedTokens,  
                  elapsed: DateTime.now().difference(startedAt),  
                );  
                break;  
              } else if (status == -1) {  
                classifyFirstTokenTermination(  
                  reason: 'native_error',  
                  boundary: 'poll_loop',  
                  runtimeReset: true,  
                );  
                _setPhase(RuntimePhase.failed);  
                clearRuntimeVerification();  
                final err = AndroidFfiRuntimeProvider._safeLastError(bindings, nativeSessionId);  
                AndroidFfiRuntimeProvider._log('[GENERATION_ERROR] stage=poll_token_native_error error=$err');  
                final statusLower = err.toLowerCase();  
                runtimeNeedsReset = true;  
                runtimeResetReason = 'native_error';  
                AndroidFfiRuntimeProvider._log(  
                  '[TERMINAL_STATE] state=native_error generated_tokens=$estimatedTokens'  
                  ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}'  
                  ' error=$err',  
                );  
                if (statusLower.contains('out of memory') ||  
                    statusLower.contains('oom') ||  
                    statusLower.contains('memory')) {  
                  _updateRuntimeStatus(LocalRuntimeStatus.failed,  
                      message: 'Out of memory: $err',  
                      tokensGenerated: estimatedTokens,  
                      elapsed: DateTime.now().difference(startedAt),  
                      startedAt: startedAt);  
                } else {  
                  _updateRuntimeStatus(  
                    LocalRuntimeStatus.failed,  
                    message: err,  
                    tokensGenerated: estimatedTokens,  
                    elapsed: DateTime.now().difference(startedAt),  
                    startedAt: startedAt,  
                  );  
                }  
                if ((statusLower.contains('timeout') || statusLower.contains('stalled')) &&  
                    fullText.toString().trim().isNotEmpty) {  
                  final partialText = _flushStructuralTemplateOutput(fullText);  
                  await AndroidFfiRuntimeProvider._finishWithPartialOrRuntimeError(  
                    controller,  
                    stage: 'generation',  
                    message: err.isNotEmpty ? err : 'Inference failed.',  
                    modelId: modelId,  
                    fullText: partialText,  
                    tokensGenerated: estimatedTokens,  
                    notice: err,  
                    partialTerminalState: InferenceTerminalState.timeout,  
                  );  
                } else {  
                  if (!controller.isClosed) {  
                    AndroidFfiRuntimeProvider._finishWithRuntimeError(  
                      controller,  
                      stage: 'generation',  
                      message: err.isNotEmpty ? err : 'Inference failed.',  
                    );  
                  }  
                }  
                break;  
              } else {  
                // status == 0: nessun token pronto; rilasciamo il controllo all'event loop.  
                consecutiveIdlePolls++;  
                if (consecutiveIdlePolls % 120 == 0) {  
                  _throttledLoopLog(  
                    '[TOKEN_STREAM] idle polling continues: idle_polls=$consecutiveIdlePolls '  
                    'idle_ms=${DateTime.now().difference(lastTokenProgressAt).inMilliseconds}',  
                  );  
                }  
                  
                // ── CRITICAL FIRST TOKEN FIX: Ottimizzazione della Latenza Iniziale ──────  
                if (_preFirstTokenActive) {  
                  // Durante l'ingestion e prima del primo token, usiamo un delay immediato  
                  // (Duration.zero) per massimizzare la reattività e non ritardare la UI mobile.  
                  await Future<void>.delayed(Duration.zero);  
                } else {  
                  // Dopo il primo token, applichiamo il meccanismo di backoff adattivo  
                  _increaseIdleBackoff();  
                  await Future<void>.delayed(Duration(milliseconds: _idleBackoffMs));  
                }  
                // ─────────────────────────────────────────────────────────────────────────  
              }  
            }  
          } finally {  
            freePromptNativePtr();  
            _discardStructuralTemplateOutput();  
            if (runtimeNeedsReset) {  
              _safeResetRuntime(  
                bindings,  
                reason: runtimeResetReason ?? 'runtime_recovery',  
              );  
            }  
            final terminalState = monitor.state.status;  
            AndroidFfiRuntimeProvider._log(  
              '[TERMINAL_STATE] state=${terminalState.name}'  
              ' generated_tokens=$estimatedTokens'  
              ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}'  
              ' first_token=${firstTokenAt != null} ffi_phase=$_currentFfiPhase',  
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
            calloc.free(tokenBufRaw);  
              
            // ── Gestione Centralizzata e Sicura di Chiusura dello Stream ───────────  
            try {  
              _releaseInferenceSlot(sessionId);  
            } catch (e, st) {  
              AndroidFfiRuntimeProvider._log('Slot release failed but forced continuation: $e\n$st');  
            }  

            final currentController = controller;  
            try {  
              if (!currentController.isClosed) {  
                await currentController.close();  
              }  
            } catch (e, st) {  
              AndroidFfiRuntimeProvider._log('Controller close non-fatal error swallowed safely: $e\n$st');  
            }  
            // ───────────────────────────────────────────────────────────────────────  
          }  
        } catch (error, stackTrace) {  
          classifyFirstTokenTermination(  
            reason: firstFfiInvocationAttempted  
                ? 'stream_inference_unhandled_post_ffi'  
                : 'stream_inference_unhandled_pre_ffi',  
            boundary: 'stream_inference',  
            cancellation: cancellationToken.isCancelled,  
            exception: true,  
          );  
          AndroidFfiRuntimeProvider._log('[FFI_EXCEPTION] session=$sessionId stage=stream_inference_unhandled error=$error');  
          AndroidFfiRuntimeProvider._log('[FFI_EXCEPTION] session=$sessionId stack=$stackTrace');  
          if (!firstFfiInvocationAttempted) {  
            await fatalEarlyExit(  
              sessionId,  
              branch: 'stream_inference_unhandled_pre_ffi',  
              reason: 'Unhandled exception before first FFI call: $error',  
              stage: 'stream_inference',  
              details: '$stackTrace',  
            );  
          } else if (!controller.isClosed) {  
            AndroidFfiRuntimeProvider._finishWithRuntimeError(  
              controller,  
              stage: 'stream_inference',  
              message: 'Unhandled runtime exception.',  
              details: '$error',  
            );  
          }  
        } finally {  
          finalizeFirstTokenAttempt();  
          AndroidFfiRuntimeProvider._log(  
            '[FFI_FLOW_EXIT] session=$sessionId first_ffi_attempted=$firstFfiInvocationAttempted'  
            ' first_ffi_completed=$firstFfiInvocationCompleted controller_closed=${controller.isClosed}',  
          );  
          if (!firstFfiInvocationAttempted) {  
            AndroidFfiRuntimeProvider._log(  
              '[PRE_FFI_ISOLATE_FAILURE_ASSERT] session=$sessionId first_ffi_attempted=false fatal=true',  
            );  
          }  
          AndroidFfiRuntimeProvider._log('[SESSION] end session=$sessionId');  
        }  
      });  
      AndroidFfiRuntimeProvider._log(  
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1655 | Function: streamInference() | AFTER calling _runInferenceSerially()',  
      );  
    } catch (e, stackTrace) {  
      AndroidFfiRuntimeProvider._log(  
        '[AI_RUNTIME_MONITOR] FORENSIC_EXCEPTION - File: android_ffi_runtime_provider.dart | Line: 1659 | Function: streamInference() | BEFORE rethrow after async execution exception: $e \n $stackTrace',  
      );  
      rethrow;  
    }  
  }, (error, stack) {  
    AndroidFfiRuntimeProvider._log('[ASYNC_CLOSURE_ZONE_UNCAUGHT] sessionId=${request.sessionId} modelId=${request.modelId} error=$error stack=$stack');  
  });  

  AndroidFfiRuntimeProvider._log(  
    '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1666 | Function: streamInference() | AFTER exit',  
  );  
  return controller.stream;  
} catch (e, stackTrace) {  
  AndroidFfiRuntimeProvider._log(  
    '[FORENSIC_UNHANDLED_EXCEPTION] error=$e stackTrace=$stackTrace',  
  );  
  rethrow;  
}

}

}
