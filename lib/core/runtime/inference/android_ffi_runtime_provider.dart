import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_bindings.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_ffi_loader.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_exceptions.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_state_machine.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ── Provider ──────────────────────────────────────────────────────────────────

/// Android inference provider that drives GGUF model execution through the
/// llama.cpp C bridge ([libllama_bridge.so]) via [dart:ffi].
///
/// Architecture
/// ─────────────
/// 1. [_ensureLibraryLoaded] opens the bridge library once and binds all
///    symbols into [LlamaBridgeBindings].
/// 2. [streamInference] creates/uses a native RuntimeSession and starts the C
///    background generation thread via `llb_session_start_gen`.
/// 3. The Dart async loop calls `llb_session_poll_token` on each iteration, yielding
///    [Future.delayed(Duration.zero)] between empty polls so the Flutter UI
///    stays responsive.
/// 4. [CancellationToken] is forwarded to `llb_session_cancel`, which signals the
///    native background thread to stop.
///
/// Native library resolution order
/// ────────────────────────────────
/// 1. `libllama_bridge.so` – preferred; thin wrapper built from
///    [native/android/llama_bridge.cpp].
///
/// Build instructions
/// ──────────────────
/// Compile the bridge from `native/android/CMakeLists.txt` and place the
/// resulting `.so` in `android/app/src/main/jniLibs/<abi>/`, or configure
/// `externalNativeBuild` in `android/app/build.gradle` to compile it
/// automatically during `flutter build apk`.
class AndroidFfiRuntimeProvider extends LocalRuntimeProvider {
  AndroidFfiRuntimeProvider({
    RuntimeStateMachine? runtimeStateMachine,
    bool Function()? developerModeProvider,
  })  : runtimeStateMachine = runtimeStateMachine ?? RuntimeStateMachine(),
        _developerModeProvider = developerModeProvider ?? (() => false),
        super(developerModeProvider: developerModeProvider);

  static const _logTag = 'AI_RUNTIME';
  static const int _safeMaxTokens = 128;
  // Keep local mobile generations bounded so stalled native loops surface
  // quickly and the UI can return partial text instead of hanging indefinitely.
  static const Duration _generationTimeout = Duration(seconds: 90);
  // If native polling produces no token at all within this window, treat the
  // run as stalled rather than waiting for the full timeout budget.
  // Keep this aligned with native/android/llama_bridge.cpp kNoTokenStallMillis.
  static const Duration _stalledInferenceTimeoutRelease = Duration(seconds: 45);
  static const Duration _stalledInferenceTimeoutDebug = Duration(seconds: 120);
  static const Duration _verificationFirstTokenTimeout = Duration(seconds: 5);
  static const Duration _noTokenProgressTimeout = Duration(seconds: 35);
  static const Duration _startGenerationTimeout = Duration(seconds: 60);
  static const Duration _modelLoadTimeout = Duration(seconds: 60);
  // 2400 polls × 24ms delay ~= 57.6s without token progress.
  // This caps idle polling so llb_session_poll_token() cannot spin forever.
  static const int _maxIdlePollIterations = 2400;
  static const int _maxRepeatedTokenLoop = 96;
  static const int _maxConsecutiveInvalidTokens = 24;
  static const String _warmupPrompt = 'Reply with the single word: OK';
  static const int _warmupMaxTokens = 4;
  static const double _warmupTemperature = 0.1;
  // Very small GGUF files are usually truncated/corrupted placeholders.
  static const int _minValidModelSizeBytes = 4096;
  static const Set<String> _androidSafeModelIds = <String>{
    LocalInferenceModelIds.llama1b,
    LocalInferenceModelIds.gemma2b,
    LocalInferenceModelIds.gemma2_2bIt,
    LocalInferenceModelIds.deepSeekR1_1_5b,
    LocalInferenceModelIds.qwen3_1_7b,
  };
  static const String _forensicSelfTestSessionId = 'runtime_self_test';

  /// Observable runtime status.  UI layers may register listeners here.
  final LocalRuntimeMonitor monitor = LocalRuntimeMonitor();
  final RuntimeStateMachine runtimeStateMachine;
  final bool Function() _developerModeProvider;

  bool get _isDeveloperMode => _developerModeProvider();

  LlamaFfiLibraryHandle? _libraryHandle;
  LlamaBridgeBindings? _bindings;
  int? _nativeSessionId;
  String? _nativeSessionModelPath;
  bool _loadAttempted = false;
  Future<void> _inferenceTail = Future<void>.value();
  Future<void>? _warmupFuture;
  String? _warmupModelPath;
  final Set<String> _activeInferenceSessions = <String>{};

  static Duration get _firstTokenTimeout =>
      kDebugMode ? _stalledInferenceTimeoutDebug : _stalledInferenceTimeoutRelease;

  // ── Library loading ──────────────────────────────────────────────────────────

  bool _ensureLibraryLoaded() {
    if (_loadAttempted) return _bindings != null && _libraryHandle != null;
    _loadAttempted = true;

    final handle = LlamaFfiLoader.tryLoadBridgeLibrary(log: _log);
    if (handle == null) return false;
    _libraryHandle = handle;
    _bindings = handle.bindings;
    _bindings!.initBackend();
    _log(
      '[FFI_INIT] Library loaded: ${LlamaFfiLoader.bridgeLibraryName}'
      ' abi=${LlamaFfiLoader.currentAbiName}',
    );
    return true;
  }

  @override
  Future<LocalRuntimeState> validateRuntime({AiModel? selectedModel}) async {
    if (!LlamaFfiLoader.isCurrentPlatformSupported) {
      final snapshot = LocalRuntimeState(
        status: LocalRuntimeStatus.failed,
        message:
            'Unsupported Android ABI (${LlamaFfiLoader.currentAbiName}). '
            'Only ${LlamaFfiLoader.supportedAbiNames} builds are supported.',
      );
      _syncLifecycleState(snapshot.status);
      return snapshot;
    }
    if (!_ensureLibraryLoaded()) {
      const snapshot = LocalRuntimeState(
        status: LocalRuntimeStatus.ffiMissing,
        message:
            'libllama_bridge.so is missing for this Android build. Rebuild the native runtime for arm64-v8a or x86_64.',
      );
      _syncLifecycleState(snapshot.status);
      return snapshot;
    }

    final snapshot = await super.validateRuntime(selectedModel: selectedModel);
    _syncLifecycleState(snapshot.status);
    return snapshot;
  }

  // ── Inference ────────────────────────────────────────────────────────────────

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    final controller = StreamController<InferenceResponse>();
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
      _log(
        '[FFI_FATAL_EARLY_EXIT] session=$sessionId branch=$branch reason=$reason',
      );
      _log(
        '[FFI_BRANCH_RETURN] session=$sessionId branch=$branch reason=$reason'
        ' first_ffi_attempted=$firstFfiInvocationAttempted first_ffi_completed=$firstFfiInvocationCompleted',
      );
      if (!controller.isClosed) {
        _finishWithRuntimeError(
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
        _log(
          '[FFI_BRANCH_RETURN] session=${request.sessionId} branch=stream_listener_cancel'
          ' reason=stream listener detached before first FFI call',
        );
      }
      _log(
        '[FFI_BRANCH] session=${request.sessionId} name=stream_listener_cancel'
        ' first_ffi_attempted=$firstFfiInvocationAttempted',
      );
    };

    () async {
      await _runInferenceSerially(() async {
      final sessionId = request.sessionId.trim().isEmpty
          ? 'unknown'
          : request.sessionId.trim();
      final dartThreadId = _currentThreadId();
      _log('[FFI_FLOW_ENTER] session=$sessionId thread_id=$dartThreadId');
      _log(
        '[RUNTIME_PROVIDER_BRANCH] provider=${runtimeType} runtime_mode=local '
        'branch=session_api local_request_available=true session=$sessionId',
      );
      _log('[SESSION] begin session=$sessionId');
      _log(
        '[DART_STREAM_LISTEN] elapsed_ms=0 thread_id=$dartThreadId token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=0 session=$sessionId',
      );
      if (!_claimInferenceSlot(sessionId)) {
        _log('[FFI_BRANCH] session=$sessionId name=recursive_inference_guard');
        _log('[SESSION] recursive_guard_triggered session=$sessionId');
        await fatalEarlyExit(
          sessionId,
          branch: 'recursive_inference_guard',
          reason: 'Recursive inference call blocked for session $sessionId.',
          stage: 'recursive_inference_guard',
        );
        _log(
          '[FFI_FLOW_EXIT] session=$sessionId first_ffi_attempted=$firstFfiInvocationAttempted'
          ' first_ffi_completed=$firstFfiInvocationCompleted controller_closed=${controller.isClosed}',
        );
        return;
      }
      try {
      if (cancellationToken.isCancelled) {
        _log('[FFI_BRANCH] session=$sessionId name=preflight_cancellation');
        await fatalEarlyExit(
          sessionId,
          branch: 'preflight_cancellation',
          reason: 'Inference cancelled before first FFI call.',
          stage: 'cancelled',
          state: InferenceTerminalState.cancelled,
        );
        return;
      }
      final modelPath = request.modelPath;
      final modelId = request.modelId;
      _log('[CONTEXT] session=$sessionId lines=${request.context.length}'
          ' system_prompt=${(request.systemPrompt ?? '').trim().isNotEmpty}');

      // ── MODEL PATH FORENSICS ─────────────────────────────────────────────────
      _log('[MODEL_PATH] modelId=$modelId path=${modelPath ?? "(null)"}'
          ' runtimeMode=android_ffi');

      if (modelPath == null || modelPath.isEmpty || modelId == null) {
        _log('[FFI_BRANCH] session=$sessionId name=request_validation_missing_path_or_id');
        _log('[MODEL_PATH] ABORT: path or modelId is null/empty');
        _log('[TERMINAL_STATE] state=modelMissing reason=missing_path_or_id');
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
      _log('[MODEL_EXISTS] path=$modelPath exists=$modelExists');
      if (modelExists) {
        int modelSizeBytes = -1;
        bool modelReadable = false;
        try {
          modelSizeBytes = modelFile.lengthSync();
          modelReadable = modelSizeBytes > 0;
        } catch (e) {
          modelReadable = false;
        }
        _log('[MODEL_SIZE] path=$modelPath size_bytes=$modelSizeBytes');
        _log('[MODEL_READABLE] path=$modelPath readable=$modelReadable');
      } else {
        _log('[MODEL_SIZE] path=$modelPath size_bytes=N/A (file not found)');
        _log('[MODEL_READABLE] path=$modelPath readable=false (file not found)');
      }

      if (!_androidSafeModelIds.contains(modelId)) {
        if (_isDeveloperMode) {
          // Developer mode: warn but allow the run to proceed.
          _log(
            '[VALIDATION] developer_mode=true: modelId=$modelId is not in the '
            'validated set – unsupported quantization or architecture possible. '
            'Proceeding with experimental inference.',
          );
          _updateRuntimeStatus(
            LocalRuntimeStatus.runtimeUnavailable,
            message:
                '[DEVELOPER MODE] $modelId is experimental – compatibility not guaranteed.',
          );
          _log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=developer_mode_unvalidated_model modelId=$modelId');
        } else {
          _log('[FFI_BRANCH] session=$sessionId name=unsupported_model_guard');
          clearRuntimeVerification();
          const unsupportedAndroidModelMessage =
              'Selected model is not enabled for Android local runtime. '
              'Use DeepSeek-R1-Distill-Qwen-1.5B, Qwen3-1.7B, '
              'gemma-2-2b-it, llama_1b, or gemma_2b.';
          _log('[TERMINAL_STATE] state=failed reason=unsupported_model modelId=$modelId');
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
      // Using compute()/Isolate.run here would require serialising a closure
      // that transitively captures `this` (via _inferenceTail: Future<void>),
      // which is not sendable and throws "Illegal argument in isolate message".
      // The check reads only 4 bytes from a local file and is effectively
      // instantaneous, so there is no benefit to offloading it.
      _log('[MODEL_VALIDATION_BEGIN] session=$sessionId task=model_validation');
      String? modelValidationError;
      try {
        modelValidationError = _validateModelFileForRuntime(modelPath);
        _log('[MODEL_VALIDATION_OK] session=$sessionId task=model_validation');
      } catch (error, stackTrace) {
        _log('[MODEL_VALIDATION_FAIL] session=$sessionId task=model_validation error=$error');
        _log('[FFI_EXCEPTION] session=$sessionId stage=model_validation stack=$stackTrace');
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
        _log('[FFI_BRANCH] session=$sessionId name=model_validation_failed');
        _log('[GGUF] validation=failed path=$modelPath reason=$modelValidationError');
        _log('[TERMINAL_STATE] state=failed reason=model_validation'
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
      _log('[GGUF] validation=ok path=$modelPath');

      final isForensicSelfTest =
          request.sessionId.trim() == _forensicSelfTestSessionId;
      if (!isForensicSelfTest) {
        final warmupReady = await _ensureWarmup(
          sessionId: sessionId,
          modelPath: modelPath,
        );
        if (!warmupReady) {
          _log('[FFI_BRANCH] session=$sessionId name=warmup_failed_non_blocking_continue');
        }
      } else {
        _log('[WARMUP] skip session=$sessionId reason=self-test owns first token contract');
      }

      if (!_ensureLibraryLoaded()) {
        _log('[FFI_BRANCH] session=$sessionId name=library_load_failed');
        _log('[TERMINAL_STATE] state=ffiMissing reason=library_load_failed');
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
      _logAi('creating native session...');
      _log('[NATIVE_MODEL_LOAD_BEGIN] path=$modelPath modelId=$modelId'
          ' n_ctx=512 n_threads=2 gpu_layers=0');

      int nativeSessionId;
      try {
        _log('[FIRST_FFI_CALL_BEGIN] session=$sessionId stage=session_create');
        _log('[FFI_PRE_CREATE_SESSION] session=$sessionId path=$modelPath');
        // This flag marks the first native entry point for this inference flow.
        firstFfiInvocationAttempted = true;
        _log('[FFI_CREATE_SESSION] path=$modelPath');
        nativeSessionId = await _runNativeCallWithTimeout<int>(
          stage: 'session_create',
          timeout: _modelLoadTimeout,
          call: () => _ensureNativeSession(bindings, modelPath),
        );
        firstFfiInvocationCompleted = true;
        _log('[FFI_POST_CREATE_SESSION] session=$sessionId native_session=$nativeSessionId');
      } catch (error) {
        _log('[FFI_EXCEPTION] session=$sessionId stage=session_create error=$error');
        _log('[SESSION_CREATE_FAIL] path=$modelPath exception=$error');
        _log('[TERMINAL_STATE] state=failed reason=session_create_exception');
        clearRuntimeVerification();
        _updateRuntimeStatus(
          error is TimeoutException
              ? LocalRuntimeStatus.timedOut
              : LocalRuntimeStatus.failed,
          message: error is TimeoutException
              ? 'Session create timed out.'
              : 'Session create failed: $error',
        );
        _finishWithRuntimeError(
          controller,
          stage: 'session_create',
          message: 'Session create failed.',
          details: error.toString(),
        );
        return;
      }
      _log('[SESSION_CREATE_OK] session=$nativeSessionId path=$modelPath');
      _log('[FFI_CREATE_SESSION_OK] session=$nativeSessionId path=$modelPath');
      final activeAfterCreate = bindings.sessionIsActive(nativeSessionId);
      _log('[NATIVE_MODEL_LOAD_RESULT] llb_session_is_active after create: $activeAfterCreate');

      if (nativeSessionId <= 0 || activeAfterCreate != 1) {
        _log('[FFI_BRANCH] session=$sessionId name=session_create_invalid_or_inactive');
        final errMsg = _safeLastError(bindings, nativeSessionId);
        _log('[SESSION_CREATE_FAIL] code=$nativeSessionId error=$errMsg path=$modelPath');
        _log('[TERMINAL_STATE] state=failed reason=session_create_error code=$nativeSessionId');
        clearRuntimeVerification();
        _updateRuntimeStatus(LocalRuntimeStatus.failed, message: errMsg);
        _finishWithRuntimeError(
          controller,
          stage: 'session_create',
          message: 'Failed to create runtime session.',
          details: 'Create failed with code $nativeSessionId: $errMsg',
        );
        return;
      }
      _log('[NATIVE_MODEL_LOAD_SUCCESS] path=$modelPath modelId=$modelId'
          ' session=$nativeSessionId');
      _log('[NATIVE_CONTEXT_CREATE] path=$modelPath status=ok');
      _logAi('native session ready');

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
        _log('[FFI_BRANCH] session=$sessionId name=tokenizer_readiness_failed');
        clearRuntimeVerification();
        _updateRuntimeStatus(
          LocalRuntimeStatus.failed,
          message: 'Tokenizer readiness check failed: prompt has no tokens.',
        );
        _finishWithRuntimeError(
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
      _log('[TOKENIZER] status=begin prompt_chars=${prompt.length}');
      _log(
        '[TOKEN_COUNT] prompt_word_estimate=$promptWordEstimate prompt_chars=${prompt.length}',
      );
      _log('[TOKENIZER_OK] prompt_word_estimate=$promptWordEstimate');
      _log(
        '[MODEL_EXECUTION] tokenization start prompt_chars=${prompt.length} prompt_word_estimate=$promptWordEstimate',
      );
      _log(
        '[CONTEXT_SIZE] session=$sessionId context_lines=${request.context.length} system_chars=${(request.systemPrompt ?? '').length} prompt_chars=${request.prompt.length} composed_prompt_chars=${prompt.length}',
      );
      _log('[KV_CACHE] layer=native status=managed_by_llama_bridge');
      _log(
        '[PROMPT_EVAL] stage=start prompt_chars=${prompt.length} prompt_word_estimate=$promptWordEstimate',
      );
      final requestedMaxTokens = isForensicSelfTest ? 4 : request.maxTokens;
      final maxTokens = requestedMaxTokens.clamp(1, _safeMaxTokens);
      final effectiveTemperature = isForensicSelfTest ? 0.1 : request.temperature;
      final effectiveTopK = isForensicSelfTest ? 1 : LlamaNativeDefaults.topK;
      final effectiveTopP = isForensicSelfTest ? 0.1 : LlamaNativeDefaults.topP;
      final firstTokenDeadline =
          isForensicSelfTest ? _verificationFirstTokenTimeout : _firstTokenTimeout;
      if (request.maxTokens > _safeMaxTokens) {
        _log(
          '[MODEL_EXECUTION] requested max_tokens=${request.maxTokens} exceeds safe limit; clamped to $maxTokens',
        );
      }

      // Verify that the native session is active before starting generation.
      final loadedCheck = bindings.sessionIsActive(nativeSessionId);
      _log('[MODEL_EXECUTION] llb_session_is_active before start_generation: $loadedCheck');
      if (loadedCheck != 1) {
        _log('[FFI_BRANCH] session=$sessionId name=session_inactive_before_start');
        clearRuntimeVerification();
        final nativeErr = _safeLastError(bindings, nativeSessionId);
        _updateRuntimeStatus(
          LocalRuntimeStatus.failed,
          message: 'Session inactive (llb_session_is_active=$loadedCheck).',
        );
        _finishWithRuntimeError(
          controller,
          stage: 'start_generation',
          message:
              'Session is not active in the native runtime (llb_session_is_active=$loadedCheck).',
          details: nativeErr.isNotEmpty ? nativeErr : null,
        );
        return;
      }

      _log(
        '[FFI_START_GEN] entering startGeneration session=$nativeSessionId '
        'prompt_chars=${prompt.length} max_tokens=$maxTokens '
        'temperature=$effectiveTemperature',
      );
      _log(
        '[GENERATION_START] session=$sessionId prompt_chars=${prompt.length}'
        ' max_tokens=$maxTokens temperature=$effectiveTemperature'
        ' n_threads=${LlamaNativeDefaults.nThreads}'
        ' n_batch=${LlamaNativeDefaults.nBatch}'
        ' n_ctx=${LlamaNativeDefaults.nCtx}'
        ' top_k=$effectiveTopK'
        ' top_p=$effectiveTopP',
      );
      _logAi('starting inference...');
      int startResult;
      final startupWatch = Stopwatch()..start();
      try {
        _log('[FFI_PRE_START] session=$sessionId native_session=$nativeSessionId');
        startResult = await _runNativeCallWithTimeout<int>(
          stage: 'start_generation',
          timeout: _startGenerationTimeout,
          call: () => bindings.startGeneration(
            nativeSessionId,
            prompt,
            maxTokens,
            effectiveTemperature,
          ),
        );
        _log(
          '[FFI_POST_START] session=$sessionId native_session=$nativeSessionId result=$startResult'
          ' elapsed_ms=${startupWatch.elapsedMilliseconds}',
        );
      } catch (error) {
        startupWatch.stop();
        _log('[FFI_EXCEPTION] session=$sessionId stage=start_generation error=$error');
        clearRuntimeVerification();
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
          _log(
            '[FFI_TIMEOUT] session=$sessionId stage=start_generation'
            ' timeout_ms=${_startGenerationTimeout.inMilliseconds}',
          );
        }
        _finishWithRuntimeError(
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
      _log('[MODEL_EXECUTION] llb_session_start_gen returned: $startResult');

      if (startupWatch.elapsed > _startGenerationTimeout) {
        _log(
          '[FFI_TIMEOUT] session=$sessionId stage=start_generation_postcheck'
          ' timeout_ms=${_startGenerationTimeout.inMilliseconds}',
        );
        _safeCancel(bindings, nativeSessionId);
        clearRuntimeVerification();
        _safeResetRuntime(bindings, reason: 'start_generation_timeout');
        _updateRuntimeStatus(
          LocalRuntimeStatus.timedOut,
          message:
              'Inference startup timed out after ${_startGenerationTimeout.inSeconds}s.',
        );
        _logAi('inference timeout');
        _finishWithRuntimeError(
          controller,
          stage: 'start_generation',
          message:
              'Inference startup timed out after ${_startGenerationTimeout.inSeconds}s.',
        );
        return;
      }

      if (startResult != 0) {
        _log('[FFI_BRANCH] session=$sessionId name=start_generation_failed_code');
        clearRuntimeVerification();
        final err = _safeLastError(bindings, nativeSessionId);
        _safeResetRuntime(bindings, reason: 'start_generation_failed');
        _updateRuntimeStatus(LocalRuntimeStatus.failed, message: err);
        _finishWithRuntimeError(
          controller,
          stage: 'start_generation',
          message: 'Failed to start generation.',
          details: err,
        );
        return;
      }
      _log('[WARMUP] inference_startup_ok session=$sessionId'
          ' startup_ms=${startupWatch.elapsed.inMilliseconds}');
      _log(
        '[PROMPT_EVAL] stage=ready startup_ms=${startupWatch.elapsed.inMilliseconds}',
      );

      cancellationToken.onCancel(() => _safeCancel(bindings, nativeSessionId));

      // ── Step 3: Poll for tokens ──────────────────────────────────────────────
      final tokenBufRaw = calloc<Uint8>(LlamaNativeDefaults.tokenBufferSize);
      final tokenBuf = tokenBufRaw.cast<Utf8>();
      var estimatedTokens = 0;
      var repeatedTokenCount = 0;
      var consecutiveInvalidTokens = 0;
      var pollIterations = 0;
      String? lastPiece;
      final fullText = StringBuffer();
      final startedAt = DateTime.now();
      DateTime? firstTokenAt;
      var lastTokenProgressAt = startedAt;
      var consecutiveIdlePolls = 0;
      var runtimeNeedsReset = false;
      String? runtimeResetReason;
      _updateRuntimeStatus(
        LocalRuntimeStatus.inferencing,
        message: 'Generating',
        tokensGenerated: 0,
        elapsed: Duration.zero,
        startedAt: startedAt,
      );
      _logAi('streaming callback active');
      _log('[STREAM_ADD] event=generation_started session=$sessionId');
      _log('[TOKEN_STREAM] loop start max_tokens=$maxTokens');
      _log('[TOKEN_LOOP] phase=start max_tokens=$maxTokens');
      _log('[FFI_PRE_POLL] session=$sessionId native_session=$nativeSessionId');
      _log('[FFI_POLL_BEGIN] session=$nativeSessionId');

      try {
        while (true) {
          pollIterations++;
          final now = DateTime.now();
          final elapsed = now.difference(startedAt);
          final sinceFirstToken =
              firstTokenAt == null ? null : now.difference(firstTokenAt);
          final sinceLastTokenProgress = now.difference(lastTokenProgressAt);
          _log(
            '[TOKEN_STREAM] poll iteration=$pollIterations tokens=$estimatedTokens elapsed_ms=${elapsed.inMilliseconds}'
            ' idle_ms=${sinceLastTokenProgress.inMilliseconds} idle_polls=$consecutiveIdlePolls',
          );
          _log(
            '[TOKEN_LOOP] iteration=$pollIterations tokens=$estimatedTokens elapsed_ms=${elapsed.inMilliseconds}',
          );
          _log(
            '[GENERATION_STEP] iteration=$pollIterations elapsed_ms=${elapsed.inMilliseconds}'
            ' generated_tokens=$estimatedTokens',
          );
          _log(
            '[GENERATION_ALIVE] iteration=$pollIterations elapsed_ms=${elapsed.inMilliseconds} first_token=${firstTokenAt != null}',
          );
          if (firstTokenAt == null && pollIterations % 25 == 0) {
            _log(
              '[FIRST_TOKEN_WAIT] iteration=$pollIterations waited_ms=${elapsed.inMilliseconds}',
            );
          }
          if (cancellationToken.isCancelled) {
            _safeCancel(bindings, nativeSessionId);
            clearRuntimeVerification();
            _log(
              '[TERMINAL_STATE] state=cancelled generated_tokens=$estimatedTokens'
              ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}',
            );
            _finishWithRuntimeError(
              controller,
              stage: 'cancelled',
              message: 'Inference cancelled.',
              state: InferenceTerminalState.cancelled,
            );
            _updateRuntimeStatus(
              LocalRuntimeStatus.runtimeUnavailable,
              message: 'Cancelled',
              tokensGenerated: estimatedTokens,
              elapsed: DateTime.now().difference(startedAt),
            );
            _log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=pre_poll_cancellation');
            break;
          }

          if (elapsed > _generationTimeout) {
            _log(
              '[FFI_TIMEOUT] session=$sessionId stage=generation_timeout'
              ' timeout_ms=${_generationTimeout.inMilliseconds}',
            );
            _safeCancel(bindings, nativeSessionId);
            clearRuntimeVerification();
            runtimeNeedsReset = true;
            runtimeResetReason = 'generation_timeout';
            _log(
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
            _logAi('inference timeout');
            await _finishWithPartialOrRuntimeError(
              controller,
              stage: 'timeout',
              message: 'Local generation timed out.',
              modelId: modelId,
              fullText: fullText.toString(),
              tokensGenerated: estimatedTokens,
              notice:
                  'Local model timed out after ${elapsed.inSeconds}s. Returning partial response.',
              partialTerminalState: InferenceTerminalState.timeout,
            );
            break;
          }
          if (firstTokenAt == null && elapsed > firstTokenDeadline) {
            _log(
              '[FFI_TIMEOUT] session=$sessionId stage=first_token_watchdog'
              ' timeout_ms=${firstTokenDeadline.inMilliseconds}',
            );
            _safeCancel(bindings, nativeSessionId);
            clearRuntimeVerification();
            runtimeNeedsReset = true;
            runtimeResetReason = 'first_token_watchdog';
            _log(
              '[STREAM_TIMEOUT] reason=no_first_token elapsed_ms=${elapsed.inMilliseconds}'
              ' timeout_ms=${firstTokenDeadline.inMilliseconds} session=$sessionId',
            );
            _log(
              '[STALL] reason=first_token_watchdog elapsed_ms=${elapsed.inMilliseconds}'
              ' no_token_produced=true session=$sessionId',
            );
            _log(
              '[FIRST_TOKEN_TIMEOUT] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=$pollIterations timeout_ms=${firstTokenDeadline.inMilliseconds}',
            );
            _log(
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
            _logAi('inference timeout');
            _finishWithRuntimeError(
              controller,
              stage: 'stalled',
              message: isForensicSelfTest
                  ? 'FIRST_TOKEN_TIMEOUT'
                  : 'Local model stalled during inference.',
            );
            break;
          }
          if (firstTokenAt != null &&
              sinceLastTokenProgress > _noTokenProgressTimeout) {
            _safeCancel(bindings, nativeSessionId);
            clearRuntimeVerification();
            runtimeNeedsReset = true;
            runtimeResetReason = 'token_progress_watchdog';
            _log(
              '[STALL] reason=token_progress_watchdog'
              ' generated_tokens=$estimatedTokens'
              ' elapsed_ms=${elapsed.inMilliseconds}'
              ' since_last_token_ms=${sinceLastTokenProgress.inMilliseconds}'
              ' session=$sessionId',
            );
            _log(
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
            await _finishWithPartialOrRuntimeError(
              controller,
              stage: 'stalled',
              message: 'Token stream stalled during local inference.',
              modelId: modelId,
              fullText: fullText.toString(),
              tokensGenerated: estimatedTokens,
              notice:
                  'Token stream stalled after ${sinceLastTokenProgress.inSeconds}s. Returning partial response.',
              partialTerminalState: InferenceTerminalState.timeout,
            );
            break;
          }
          if (consecutiveIdlePolls >= _maxIdlePollIterations) {
            _safeCancel(bindings, nativeSessionId);
            clearRuntimeVerification();
            runtimeNeedsReset = true;
            runtimeResetReason = 'poll_loop_watchdog';
            _log(
              '[STREAM_TIMEOUT] reason=poll_loop_idle idle_polls=$consecutiveIdlePolls'
              ' elapsed_ms=${elapsed.inMilliseconds} session=$sessionId',
            );
            _log(
              '[STALL] reason=poll_loop_watchdog'
              ' idle_polls=$consecutiveIdlePolls generated_tokens=$estimatedTokens'
              ' elapsed_ms=${elapsed.inMilliseconds} session=$sessionId',
            );
            _log(
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
            await _finishWithPartialOrRuntimeError(
              controller,
              stage: 'poll_loop',
              message: 'Token polling stalled in local runtime.',
              modelId: modelId,
              fullText: fullText.toString(),
              tokensGenerated: estimatedTokens,
              notice:
                  'No token progress detected in polling loop. Returning partial response.',
              partialTerminalState: InferenceTerminalState.timeout,
            );
            break;
          }

          int status;
          try {
            _log(
              '[FFI_POLL_BEGIN] entering pollToken session=$nativeSessionId '
              'iteration=$pollIterations',
            );
            _log(
              '[FFI_CALLBACK_ENTER] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 poll_iteration=$pollIterations',
            );
            status = bindings.pollToken(nativeSessionId, tokenBuf);
          } catch (error) {
            clearRuntimeVerification();
            runtimeNeedsReset = true;
            runtimeResetReason = 'poll_token_exception';
            _updateRuntimeStatus(
              LocalRuntimeStatus.failed,
              message: 'Native poll_token failed: $error',
            );
            _finishWithRuntimeError(
              controller,
              stage: 'poll_token',
              message: 'Native poll_token failed.',
              details: error.toString(),
            );
            break;
          }
          _log('[TOKEN_STREAM] poll status iteration=$pollIterations status=$status');
          _log(
            '[FFI_CALLBACK_PAYLOAD] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 poll_iteration=$pollIterations status=$status',
          );

          if (status == 1) {
            String piece;
            try {
              piece = tokenBuf.toDartString();
            } catch (error) {
              _log('[TOKENIZER_DECODE_FAIL] stage=dart_utf8_decode error=$error');
              consecutiveInvalidTokens++;
              if (consecutiveInvalidTokens >= _maxConsecutiveInvalidTokens) {
                _safeCancel(bindings, nativeSessionId);
                clearRuntimeVerification();
                runtimeNeedsReset = true;
                runtimeResetReason = 'token_decode_exception';
                _log(
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
                _finishWithRuntimeError(
                  controller,
                  stage: 'token_decode',
                  message: 'Invalid generated token stream.',
                  details: error.toString(),
                );
                break;
              }
              continue;
            }
            if (piece.isNotEmpty) {
              final isFirstToken = firstTokenAt == null;
              firstTokenAt ??= DateTime.now();
              consecutiveInvalidTokens = 0;
              consecutiveIdlePolls = 0;
              lastTokenProgressAt = DateTime.now();
              fullText.write(piece);
              estimatedTokens++;
              markRuntimeVerified(modelPath);
              final streamingElapsed = DateTime.now().difference(startedAt);
              _log(
                '[FFI_CALLBACK_PAYLOAD] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${piece.length} poll_iteration=$pollIterations status=$status',
              );
              _log(
                '[DART_STREAM_RECEIVE] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${piece.length} poll_iteration=$pollIterations subscription_alive=${!controller.isClosed}',
              );
              if (isFirstToken) {
                _log(
                  '[FFI_FIRST_TOKEN] session=$nativeSessionId elapsed_ms=${streamingElapsed.inMilliseconds} chars=${piece.length}',
                );
                _log(
                  '[FIRST_TOKEN] elapsed_ms=${streamingElapsed.inMilliseconds}'
                  ' token_text_length=${piece.length}'
                  ' poll_iteration=$pollIterations session=$sessionId',
                );
                _log(
                  '[FIRST_TOKEN_REAL] elapsed_ms=${streamingElapsed.inMilliseconds}'
                  ' thread_id=$dartThreadId token_id=-1 token_text_length=${piece.length}'
                  ' queue_size=-1 poll_iteration=$pollIterations'
                  ' token="${piece.replaceAll('\n', r'\n')}" token_count=$estimatedTokens',
                );
              }
              _log(
                '[DART_TOKEN_RECEIVED] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${piece.length} queue_size=-1 poll_iteration=$pollIterations',
              );
              _log('[FFI_TOKEN] session=$nativeSessionId chars=${piece.length}');
              if (estimatedTokens % 16 == 0) {
                _log('[TOKEN_STREAM] token_count=$estimatedTokens');
              }
              _log(
                '[TOKEN_STREAM] piece token_index=$estimatedTokens text="${piece.replaceAll('\n', r'\n')}"'
                ' total_chars=${fullText.length} since_first_token_ms=${sinceFirstToken?.inMilliseconds ?? 0}',
              );
              _log(
                '[TOKEN_EVAL] token_index=$estimatedTokens elapsed_ms=${streamingElapsed.inMilliseconds}',
              );
              _log(
                '[TOKEN_DECODE] token_index=$estimatedTokens chars=${piece.length}'
                ' text="${piece.replaceAll('\n', r'\n')}"',
              );
              if (piece == lastPiece) {
                repeatedTokenCount++;
                if (repeatedTokenCount >= _maxRepeatedTokenLoop) {
                  _safeCancel(bindings, nativeSessionId);
                  clearRuntimeVerification();
                  runtimeNeedsReset = true;
                  runtimeResetReason = 'repeated_token_loop';
                  _log(
                    '[STREAM_LOOP] reason=repeated_token'
                    ' count=$repeatedTokenCount token="${piece.replaceAll('\n', r'\n')}"'
                    ' generated_tokens=$estimatedTokens session=$sessionId',
                  );
                  _log(
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
                  _finishWithRuntimeError(
                    controller,
                    stage: 'generation_loop',
                    message: 'Repeated-token loop detected.',
                    details: 'token="$piece"',
                  );
                  break;
                }
              } else {
                lastPiece = piece;
                repeatedTokenCount = 0;
              }
              _updateRuntimeStatus(
                LocalRuntimeStatus.streaming,
                message: 'Streaming',
                tokensGenerated: estimatedTokens,
                elapsed: streamingElapsed,
                startedAt: startedAt,
              );
              _log(
                '[TOKEN_EMIT] token_index=$estimatedTokens chars=${piece.length}'
                ' session=$sessionId',
              );
              _log(
                '[DART_STREAM_RENDER] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${piece.length} queue_size=-1 poll_iteration=$pollIterations subscription_alive=${!controller.isClosed}',
              );
              _log('[STREAM_ADD] event=token session=$sessionId');
              final flushWatch = Stopwatch()..start();
              controller.add(InferenceResponse.token(text: piece, model: modelId));
              flushWatch.stop();
              _log(
                '[STREAM_FLUSH] event=token session=$sessionId flush_us=${flushWatch.elapsedMicroseconds}',
              );
            } else {
              consecutiveInvalidTokens++;
              _log(
                '[TOKEN_STREAM] empty token iteration=$pollIterations consecutive_empty=$consecutiveInvalidTokens',
              );
              if (consecutiveInvalidTokens >= _maxConsecutiveInvalidTokens) {
                _log('[TOKENIZER_DECODE_FAIL] stage=empty_piece_loop');
                _safeCancel(bindings, nativeSessionId);
                clearRuntimeVerification();
                runtimeNeedsReset = true;
                runtimeResetReason = 'empty_token_loop';
                _log(
                  '[TERMINAL_STATE] state=failed reason=empty_token_loop'
                  ' generated_tokens=$estimatedTokens'
                  ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}',
                );
                _updateRuntimeStatus(
                  LocalRuntimeStatus.failed,
                  message: 'Invalid empty token stream.',
                  tokensGenerated: estimatedTokens,
                  elapsed: DateTime.now().difference(startedAt),
                  startedAt: startedAt,
                );
                _finishWithRuntimeError(
                  controller,
                  stage: 'token_decode',
                  message: 'Invalid token stream.',
                );
                break;
              }
            }
          } else if (status == 2) {
            // EOS or max-tokens: generation complete.
            final completedElapsed = DateTime.now().difference(startedAt);
            markRuntimeVerified(modelPath);
            _log('[FFI_EOS] session=$nativeSessionId');
            _log(
              '[GENERATION_END] state=success generated_tokens=$estimatedTokens'
              ' elapsed_ms=${completedElapsed.inMilliseconds}',
            );
            _log(
              '[FINAL_RESPONSE] eos generated_tokens=$estimatedTokens elapsed_ms=${completedElapsed.inMilliseconds}',
            );
            _log(
              '[TERMINAL_STATE] state=success generated_tokens=$estimatedTokens'
              ' elapsed_ms=${completedElapsed.inMilliseconds}',
            );
            _logAi('inference completed');
            _log('[STREAM_ADD] event=final_chunk session=$sessionId');
            final flushWatch = Stopwatch()..start();
            controller.add(InferenceResponse.finalChunk(
              text: fullText.toString(),
              tokensGenerated: estimatedTokens,
              model: modelId,
            ));
            flushWatch.stop();
            _log(
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
            // Cancelled by the native thread.
            _log('[GENERATION_END] state=cancelled generated_tokens=$estimatedTokens');
            _log(
              '[TERMINAL_STATE] state=cancelled generated_tokens=$estimatedTokens'
              ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}',
            );
            clearRuntimeVerification();
            _finishWithRuntimeError(
              controller,
              stage: 'cancelled',
              message: 'Inference cancelled.',
              state: InferenceTerminalState.cancelled,
            );
            _log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=native_cancelled');
            _updateRuntimeStatus(
              LocalRuntimeStatus.runtimeUnavailable,
              tokensGenerated: estimatedTokens,
              elapsed: DateTime.now().difference(startedAt),
            );
            _log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=native_cancelled_status');
            break;
          } else if (status == -1) {
            clearRuntimeVerification();
            final err = _safeLastError(bindings, nativeSessionId);
            _log('[GENERATION_ERROR] stage=poll_token_native_error error=$err');
            final statusLower = err.toLowerCase();
            runtimeNeedsReset = true;
            runtimeResetReason = 'native_error';
            _log(
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
              await _finishWithPartialOrRuntimeError(
                controller,
                stage: 'generation',
                message: err.isNotEmpty ? err : 'Inference failed.',
                modelId: modelId,
                fullText: fullText.toString(),
                tokensGenerated: estimatedTokens,
                notice: err,
                partialTerminalState: InferenceTerminalState.timeout,
              );
            } else {
              _finishWithRuntimeError(
                controller,
                stage: 'generation',
                message: err.isNotEmpty ? err : 'Inference failed.',
              );
            }
            break;
          } else {
            // status == 0: no token ready yet; yield to the Flutter event loop.
            // Use a small non-zero delay to avoid excessive CPU churn during
            // periods when the generation thread has not yet produced output.
            consecutiveIdlePolls++;
            if (consecutiveIdlePolls % 120 == 0) {
              _log(
                '[TOKEN_STREAM] idle polling continues: idle_polls=$consecutiveIdlePolls '
                'idle_ms=${DateTime.now().difference(lastTokenProgressAt).inMilliseconds}',
              );
              _log(
                '[GENERATION_IDLE] idle_polls=$consecutiveIdlePolls idle_ms=${DateTime.now().difference(lastTokenProgressAt).inMilliseconds}',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 24));
          }
        }
      } finally {
        if (runtimeNeedsReset) {
          _safeResetRuntime(
            bindings,
            reason: runtimeResetReason ?? 'runtime_recovery',
          );
        }
        final terminalState = monitor.state.status;
        _log(
          '[TERMINAL_STATE] state=${terminalState.name}'
          ' generated_tokens=$estimatedTokens'
          ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}'
          ' first_token=${firstTokenAt != null}',
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
        if (!controller.isClosed) {
          _log('[FFI_STREAM_CLOSE] session=$sessionId reason=stream_finally_close');
          _log(
            '[DART_STREAM_CLOSE] elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=$pollIterations session=$sessionId',
          );
          _log('[STREAM_CLOSE] session=$sessionId');
          await controller.close();
        }
      }
      } catch (error, stackTrace) {
        _log('[FFI_EXCEPTION] session=$sessionId stage=stream_inference_unhandled error=$error');
        _log('[FFI_EXCEPTION] session=$sessionId stack=$stackTrace');
        if (!firstFfiInvocationAttempted) {
          // Classification is based on whether session_create has been attempted yet.
          await fatalEarlyExit(
            sessionId,
            branch: 'stream_inference_unhandled_pre_ffi',
            reason: 'Unhandled exception before first FFI call: $error',
            stage: 'stream_inference',
            details: '$stackTrace',
          );
        } else if (!controller.isClosed) {
          _finishWithRuntimeError(
            controller,
            stage: 'stream_inference',
            message: 'Unhandled runtime exception.',
            details: '$error',
          );
        } else {
          _log(
            '[FFI_EXCEPTION] session=$sessionId stage=stream_inference_post_ffi_controller_closed'
            ' error=$error',
          );
        }
      } finally {
        _log(
          '[FFI_FLOW_EXIT] session=$sessionId first_ffi_attempted=$firstFfiInvocationAttempted'
          ' first_ffi_completed=$firstFfiInvocationCompleted controller_closed=${controller.isClosed}',
        );
        if (!firstFfiInvocationAttempted) {
          _log(
            '[FFI_FATAL_EARLY_EXIT] session=$sessionId reason=stream_exit_before_first_ffi'
            ' controller_closed=${controller.isClosed}',
          );
          _log(
            '[PRE_FFI_ISOLATE_FAILURE_ASSERT] session=$sessionId first_ffi_attempted=false'
            ' fatal=true',
          );
        }
        _releaseInferenceSlot(sessionId);
        _log('[SESSION] end session=$sessionId');
      }
      });
    }();

    return controller.stream;
  }

  // ── Private helpers ───────────────────────────────────────────────────────────

  int _ensureNativeSession(LlamaBridgeBindings bindings, String modelPath) {
    if (_nativeSessionId != null &&
        _nativeSessionModelPath == modelPath &&
        bindings.sessionIsActive(_nativeSessionId!) == 1) {
      _log('[SESSION_CREATE_OK] reusing session=$_nativeSessionId path=$modelPath');
      _log('[FFI_CREATE_SESSION_OK] reusing=true session=$_nativeSessionId path=$modelPath');
      return _nativeSessionId!;
    }

    _releaseNativeSessionIfPresent(bindings);

    _log('[FFI_CREATE_SESSION] entering createSession path=$modelPath');
    final created = bindings.createSession(modelPath);
    _log('[FFI_CREATE_SESSION_RETURN] returned_session_id=$created path=$modelPath');
    if (created <= 0) {
      _log('[SESSION_CREATE_FAIL] path=$modelPath session=$created');
      final err = _safeLastError(bindings, created);
      throw StateError('Native session creation failed: $err');
    }
    if (bindings.sessionIsActive(created) != 1) {
      _log('[SESSION_CREATE_FAIL] path=$modelPath session=$created inactive_after_create');
      final err = _safeLastError(bindings, created);
      throw StateError('Native session inactive after create: $err');
    }

    _nativeSessionId = created;
    _nativeSessionModelPath = modelPath;
    _log('[SESSION_CREATE_OK] path=$modelPath session=$created');
    _log('[FFI_CREATE_SESSION_OK] path=$modelPath session=$created');
    return created;
  }

  void _releaseNativeSessionIfPresent(LlamaBridgeBindings bindings) {
    final sessionId = _nativeSessionId;
    if (sessionId == null) return;
    try {
      // Native release is intentionally non-blocking; cleanup continues in C++.
      _log('[FFI_RELEASE] session=$sessionId');
      bindings.releaseSession(sessionId);
    } catch (error) {
      _log('[FFI_RELEASE] session=$sessionId failed: $error');
    } finally {
      _nativeSessionId = null;
      _nativeSessionModelPath = null;
    }
  }

  Future<void> _runInferenceSerially(Future<void> Function() action) {
    final next = _inferenceTail.then((_) => action());
    _inferenceTail = next.catchError((_) {});
    return next;
  }

  Future<T> _runNativeCallWithTimeout<T>({
    required String stage,
    required Duration timeout,
    required T Function() call,
  }) async {
    _log('[WARMUP] native_call stage=$stage timeout_ms=${timeout.inMilliseconds}');
    return Future<T>.sync(call).timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Native call timed out at stage=$stage after ${timeout.inSeconds}s.',
      ),
    );
  }

  bool _claimInferenceSlot(String sessionId) {
    if (_activeInferenceSessions.contains(sessionId)) return false;
    _activeInferenceSessions.add(sessionId);
    return true;
  }

  void _releaseInferenceSlot(String sessionId) {
    _activeInferenceSessions.remove(sessionId);
  }

  /// Returns true when warmup succeeds.
  /// Returns false when warmup fails, but inference continues to createSession
  /// so runtime verification remains observational instead of a hard gate.
  Future<bool> _ensureWarmup({
    required String sessionId,
    required String modelPath,
  }) async {
    if (_warmupFuture == null || _warmupModelPath != modelPath) {
      _warmupModelPath = modelPath;
      _warmupFuture = _runWarmup(modelPath: modelPath);
    }
    _log('[WARMUP] await session=$sessionId');
    try {
      await _warmupFuture!;
      _log('[WARMUP] complete session=$sessionId');
      return true;
    } catch (error) {
      _warmupFuture = null;
      clearRuntimeVerification();
      _log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=warmup_failed error=$error');
      _updateRuntimeStatus(
        LocalRuntimeStatus.runtimeUnavailable,
        message: 'Runtime warmup failed: $error',
      );
      _log(
        '[FFI_BRANCH] session=$sessionId name=warmup_failed_observational'
        ' action=continue_to_create_session',
      );
      return false;
    }
  }

  Future<void> _runWarmup({required String modelPath}) async {
    _log('[BOOT] runtime warmup begin');
    _updateRuntimeStatus(
      LocalRuntimeStatus.loading,
      message: 'Runtime warmup in progress...',
      resetProgress: true,
    );
    if (!LlamaFfiLoader.isCurrentPlatformSupported) {
      throw StateError('Unsupported Android ABI (${LlamaFfiLoader.currentAbiName}).');
    }
    if (!_ensureLibraryLoaded()) {
      throw StateError('libllama_bridge.so is missing for this Android build.');
    }
    final bindings = _bindings!;
    _log('[BOOT] runtime warmup library ready');
    _log('[FFI_CREATE_SESSION] warmup path=$modelPath');
    final warmupSessionId = bindings.createSession(modelPath);
    if (warmupSessionId <= 0) {
      throw StateError(
        'Warmup session creation failed: ${_safeLastError(bindings, warmupSessionId)}',
      );
    }
    if (bindings.sessionIsActive(warmupSessionId) != 1) {
      bindings.releaseSession(warmupSessionId);
      throw StateError(
        'Warmup session inactive: ${_safeLastError(bindings, warmupSessionId)}',
      );
    }
    _log('[FFI_CREATE_SESSION_OK] warmup session=$warmupSessionId');
    final tokenBufRaw = calloc<Uint8>(LlamaNativeDefaults.tokenBufferSize);
    final tokenBuf = tokenBufRaw.cast<Utf8>();
    var firstTokenSeen = false;
    final stopwatch = Stopwatch()..start();
    try {
      _log('[FFI_START_GEN] entering startGeneration session=$warmupSessionId warmup=true');
      final start = bindings.startGeneration(
        warmupSessionId,
        _warmupPrompt,
        _warmupMaxTokens,
        _warmupTemperature,
      );
      if (start != 0) {
        throw StateError(
          'Warmup generation start failed: ${_safeLastError(bindings, warmupSessionId)}',
        );
      }
      while (stopwatch.elapsed < _verificationFirstTokenTimeout) {
        _log('[FFI_POLL_BEGIN] entering pollToken session=$warmupSessionId warmup=true');
        final status = bindings.pollToken(warmupSessionId, tokenBuf);
        if (status == 1) {
          final token = tokenBuf.toDartString();
          if (token.trim().isNotEmpty) {
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
            'Warmup generation failed: ${_safeLastError(bindings, warmupSessionId)}',
          );
        } else if (status == -99) {
          throw StateError('Warmup generation cancelled before first token.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 24));
      }
      if (!firstTokenSeen) {
        throw StateError('FIRST_TOKEN_TIMEOUT');
      }
    } finally {
      calloc.free(tokenBufRaw);
      _log('[FFI_CANCEL] warmup session=$warmupSessionId');
      bindings.cancelSession(warmupSessionId);
      _log('[FFI_RELEASE] warmup session=$warmupSessionId');
      bindings.releaseSession(warmupSessionId);
    }
  }

  static void _finishWithError(
    StreamController<InferenceResponse> ctrl,
    String message, {
    InferenceTerminalState state = InferenceTerminalState.failed,
  }) {
    if (ctrl.isClosed) return;
    ctrl.add(InferenceResponse.error(message, state: state));
    _log('[FFI_STREAM_CLOSE] reason=finish_with_error');
    _log(
      '[DART_STREAM_CLOSE] elapsed_ms=0 thread_id=${_currentThreadId()} token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=-1 reason=finish_with_error',
    );
    _log('[STREAM_CLOSE] reason=finish_with_error');
    ctrl.close();
  }

  static void _finishWithRuntimeError(
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
    _finishWithError(ctrl, payload, state: state);
  }

  static Future<void> _finishWithPartialOrRuntimeError(
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
      await ctrl.close();
      _log(
        '[DART_STREAM_CLOSE] elapsed_ms=0 thread_id=${_currentThreadId()} token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=-1 reason=partial_or_runtime_error',
      );
      _log('[STREAM_CLOSE] reason=partial_or_runtime_error');
      return;
    }
    _finishWithRuntimeError(
      ctrl,
      stage: stage,
      message: message,
      state: partialTerminalState,
    );
  }

  String _composePrompt(
    InferenceRequest request, {
    required String modelId,
    bool bypassNonessentialLayers = false,
  }) {
    if (bypassNonessentialLayers) {
      _log(
        '[FORENSIC_BYPASS] session=${request.sessionId} mode=raw_prompt_only semantic_memory=false embeddings=false workspace_indexing=false retrieval_augmentation=false conversation_rebuild=false',
      );
      return request.prompt.trim();
    }
    return LocalPromptTemplates.compose(
      modelId: modelId,
      prompt: request.prompt,
      systemPrompt: request.systemPrompt,
      context: request.context,
    );
  }

  static String? _validateModelFileForRuntime(String modelPath) {
    final file = File(modelPath);
    if (!file.existsSync()) {
      return 'Selected model file does not exist.';
    }
    if (!modelPath.toLowerCase().endsWith('.gguf')) {
      return 'Selected model is not a GGUF file.';
    }
    RandomAccessFile? handle;
    try {
      handle = file.openSync(mode: FileMode.read);
      final length = handle.lengthSync();
      if (length <= _minValidModelSizeBytes) {
        return 'Selected model appears truncated or corrupted.';
      }
      final header = handle.readSync(4);
      if (header.length < 4 ||
          header[0] != 0x47 ||
          header[1] != 0x47 ||
          header[2] != 0x55 ||
          header[3] != 0x46) {
        return 'Selected model has an invalid GGUF header.';
      }
      return null;
    } catch (_) {
      return 'Selected model file is not readable.';
    } finally {
      handle?.closeSync();
    }
  }

  static String _safeLastError(LlamaBridgeBindings bindings, int sessionId) {
    try {
      final value = bindings.sessionLastError(sessionId);
      if (value.trim().isEmpty) return 'Unknown native runtime error.';
      _log('[MODEL_EXECUTION] native error: $value');
      return value;
    } catch (error) {
      _log('[MODEL_EXECUTION] llb_session_last_error failed: $error');
      return 'Native runtime error (unable to read details).';
    }
  }

  void _safeCancel(LlamaBridgeBindings bindings, int sessionId) {
    try {
      _log('[FFI_CANCEL] session=$sessionId');
      bindings.cancelSession(sessionId);
    } catch (error) {
      _log('[MODEL_EXECUTION] llb_session_cancel failed: $error');
    }
  }

  void _safeResetRuntime(
    LlamaBridgeBindings bindings, {
    required String reason,
  }) {
    try {
      _log('[MODEL_EXECUTION] resetting native runtime: $reason');
      final sessionId = _nativeSessionId;
      if (sessionId != null) {
        _log('[MODEL_EXECUTION] llb_session_is_active before reset: ${bindings.sessionIsActive(sessionId)}');
        _safeCancel(bindings, sessionId);
      }
      _releaseNativeSessionIfPresent(bindings);
    } catch (error) {
      _log('[MODEL_EXECUTION] runtime reset failed: $error');
    }
  }

  static void _log(String message) {
    debugPrint('[$_logTag] $message');
    RuntimeEventLog.instance.emit(message);
  }

  static void _logAi(String message) {
    debugPrint('[AI] $message');
  }

  static int _currentThreadId() => Isolate.current.hashCode;

  void _updateRuntimeStatus(
    LocalRuntimeStatus status, {
    String? message,
    int? tokensGenerated,
    Duration? elapsed,
    DateTime? startedAt,
    bool resetProgress = false,
  }) {
    monitor.update(
      status,
      message: message,
      tokensGenerated: tokensGenerated,
      elapsed: elapsed,
      startedAt: startedAt,
      resetProgress: resetProgress,
    );
    _syncLifecycleState(status);
  }

  void _syncLifecycleState(LocalRuntimeStatus status) {
    switch (status) {
      case LocalRuntimeStatus.uninitialized:
      case LocalRuntimeStatus.runtimeUnavailable:
      case LocalRuntimeStatus.modelMissing:
        runtimeStateMachine.reset();
        return;
      case LocalRuntimeStatus.loading:
      case LocalRuntimeStatus.tokenizing:
        runtimeStateMachine.markLoading();
        return;
      case LocalRuntimeStatus.ready:
        runtimeStateMachine.markReady();
        return;
      case LocalRuntimeStatus.completed:
        runtimeStateMachine.markInferenceCompleted();
        return;
      case LocalRuntimeStatus.inferencing:
      case LocalRuntimeStatus.streaming:
        runtimeStateMachine.markInferencing();
        return;
      case LocalRuntimeStatus.timedOut:
      case LocalRuntimeStatus.stalled:
      case LocalRuntimeStatus.ffiMissing:
      case LocalRuntimeStatus.failed:
        runtimeStateMachine.markFailed();
        return;
    }
  }

}

