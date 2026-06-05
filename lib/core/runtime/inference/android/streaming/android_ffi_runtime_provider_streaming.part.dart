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
        final dartThreadId = AndroidFfiRuntimeProvider._currentThreadId();
        final isForensicSelfTest = request.sessionId.trim() == AndroidFfiRuntimeProvider._forensicSelfTestSessionId;
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
            ' modelId=${request.modelId} is_verification=$isForensicSelfTest',
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
        if (!isForensicSelfTest && !_claimInferenceSlot(sessionId)) {
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
        if (isForensicSelfTest) {
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

            await _runTokenPollingLoop(
            controller: controller,
            cancellationToken: cancellationToken,
            bindings: bindings,
            sessionId: sessionId,
            modelId: modelId,
            modelPath: modelPath,
            nativeSessionId: nativeSessionId,
            promptNativePtr: promptNativePtr,
            freePromptNativePtr: freePromptNativePtr,
            isForensicSelfTest: isForensicSelfTest,
            maxTokens: maxTokens,
            dartThreadId: dartThreadId,
            firstTokenDeadline: firstTokenDeadline,
            );
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
