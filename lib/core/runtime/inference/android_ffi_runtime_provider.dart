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
import 'package:ai_orchestrator/core/runtime/inference/runtime_exceptions.dart';
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
/// 2. [streamInference] loads the GGUF model and starts the C background
///    thread via `llb_start_gen` inside the same native runtime instance.
/// 3. The Dart async loop calls `llb_poll_token` on each iteration, yielding
///    [Future.delayed(Duration.zero)] between empty polls so the Flutter UI
///    stays responsive.
/// 4. [CancellationToken] is forwarded to `llb_cancel`, which signals the
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
  static const _logTag = 'AI_RUNTIME';
  static const int _safeMaxTokens = 128;
  // Keep local mobile generations bounded so stalled native loops surface
  // quickly and the UI can return partial text instead of hanging indefinitely.
  static const Duration _generationTimeout = Duration(seconds: 90);
  // Hard pre-inference watchdog: if no first token arrives within this
  // window the failure is almost certainly in FFI open / symbol binding /
  // GGUF path resolution or native context creation — not generation itself.
  // Fires before _stalledInferenceTimeout to surface stalled_pre_inference
  // conclusively.
  static const Duration _preInferenceTimeout = Duration(seconds: 15);
  // If native polling produces no token at all within this window, treat the
  // run as stalled rather than waiting for the full timeout budget.
  // Keep this aligned with native/android/llama_bridge.cpp kNoTokenStallMillis.
  static const Duration _stalledInferenceTimeout = Duration(seconds: 45);
  static const Duration _noTokenProgressTimeout = Duration(seconds: 35);
  static const Duration _startGenerationTimeout = Duration(seconds: 60);
  // 2400 polls × 24ms delay ~= 57.6s without token progress.
  // This caps idle polling so llb_poll_token() cannot spin forever.
  static const int _maxIdlePollIterations = 2400;
  static const int _maxRepeatedTokenLoop = 96;
  static const int _maxConsecutiveInvalidTokens = 24;
  // Very small GGUF files are usually truncated/corrupted placeholders.
  static const int _minValidModelSizeBytes = 4096;
  static const Set<String> _androidSafeModelIds = <String>{
    LocalInferenceModelIds.llama1b,
    LocalInferenceModelIds.gemma2b,
    LocalInferenceModelIds.gemma2_2bIt,
    LocalInferenceModelIds.deepSeekR1_1_5b,
    LocalInferenceModelIds.qwen3_1_7b,
  };

  /// Observable runtime status.  UI layers may register listeners here.
  final LocalRuntimeMonitor monitor = LocalRuntimeMonitor();

  LlamaFfiLibraryHandle? _libraryHandle;
  LlamaBridgeBindings? _bindings;
  bool _loadAttempted = false;
  Future<void> _inferenceTail = Future<void>.value();

  // ── Library loading ──────────────────────────────────────────────────────────

  bool _ensureLibraryLoaded() {
    if (_loadAttempted) return _bindings != null && _libraryHandle != null;
    _loadAttempted = true;

    final handle = LlamaFfiLoader.tryLoadBridgeLibrary(log: _log);
    if (handle == null) return false;
    _libraryHandle = handle;
    _bindings = handle.bindings;
    _log(
      '[FFI_INIT] Library loaded: ${LlamaFfiLoader.bridgeLibraryName}'
      ' abi=${LlamaFfiLoader.currentAbiName}',
    );
    return true;
  }

  @override
  Future<LocalRuntimeState> validateRuntime({AiModel? selectedModel}) async {
    if (!LlamaFfiLoader.isCurrentPlatformSupported) {
      return LocalRuntimeState(
        status: LocalRuntimeStatus.failed,
        message:
            'Unsupported Android ABI (${LlamaFfiLoader.currentAbiName}). '
            'Only ${LlamaFfiLoader.supportedAbiNames} builds are supported.',
      );
    }
    if (!_ensureLibraryLoaded()) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.ffiMissing,
        message:
            'libllama_bridge.so is missing for this Android build. Rebuild the native runtime for arm64-v8a or x86_64.',
      );
    }

    return super.validateRuntime(selectedModel: selectedModel);
  }

  // ── Inference ────────────────────────────────────────────────────────────────

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    final controller = StreamController<InferenceResponse>();

    () async {
      await _runInferenceSerially(() async {
      if (cancellationToken.isCancelled) {
        _finishWithRuntimeError(
          controller,
          stage: 'cancelled',
          message: 'Inference cancelled.',
          state: InferenceTerminalState.cancelled,
        );
        return;
      }
      final modelPath = request.modelPath;
      final modelId = request.modelId;

      // ── MODEL PATH FORENSICS ─────────────────────────────────────────────────
      _log('[MODEL_PATH] modelId=$modelId path=${modelPath ?? "(null)"}'
          ' runtimeMode=android_ffi');

      if (modelPath == null || modelPath.isEmpty || modelId == null) {
        _log('[MODEL_PATH] ABORT: path or modelId is null/empty');
        _log('[TERMINAL_STATE] state=modelMissing reason=missing_path_or_id');
        clearRuntimeVerification();
        monitor.update(
          LocalRuntimeStatus.modelMissing,
          message: 'No validated local model is selected.',
        );
        _finishWithRuntimeError(
          controller,
          stage: 'request_validation',
          message: 'Missing local model path.',
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
        clearRuntimeVerification();
        const unsupportedAndroidModelMessage =
            'Selected model is not enabled for Android local runtime. '
            'Use DeepSeek-R1-Distill-Qwen-1.5B, Qwen3-1.7B, '
            'gemma-2-2b-it, llama_1b, or gemma_2b.';
        _log('[TERMINAL_STATE] state=failed reason=unsupported_model modelId=$modelId');
        monitor.update(
          LocalRuntimeStatus.failed,
          message: unsupportedAndroidModelMessage,
        );
        _finishWithRuntimeError(
          controller,
          stage: 'model_guard',
          message: unsupportedAndroidModelMessage,
          details: 'modelId=$modelId',
        );
        return;
      }

      final modelValidationError =
          await Isolate.run(() => _validateModelFileForRuntime(modelPath));
      if (modelValidationError != null) {
        _log('[TERMINAL_STATE] state=failed reason=model_validation'
            ' path=$modelPath error=$modelValidationError');
        clearRuntimeVerification();
        monitor.update(LocalRuntimeStatus.failed, message: modelValidationError);
        _finishWithRuntimeError(
          controller,
          stage: 'model_validation',
          message: modelValidationError,
        );
        return;
      }

      if (!_ensureLibraryLoaded()) {
        _log('[TERMINAL_STATE] state=ffiMissing reason=library_load_failed');
        clearRuntimeVerification();
        monitor.update(
          LocalRuntimeStatus.ffiMissing,
          message:
              'libllama_bridge.so is missing for this Android build.',
        );
        _finishWithRuntimeError(
          controller,
          stage: 'library_load',
          message: 'Local AI runtime library (libllama_bridge.so) not found.',
        );
        return;
      }

      final bindings = _bindings!;

      // ── Step 1: Load model ───────────────────────────────────────────────────
      monitor.update(LocalRuntimeStatus.loading,
          message: 'Loading model: $modelId', resetProgress: true);
      // Let UI observers process the loading state before the blocking FFI load.
      await Future<void>.delayed(Duration.zero);
      _logAi('loading model...');
      _log('[NATIVE_MODEL_LOAD_BEGIN] path=$modelPath modelId=$modelId'
          ' n_ctx=512 n_threads=2 gpu_layers=0');

      int loadResult;
      try {
        loadResult = bindings.loadModel(modelPath);
      } catch (error) {
        _log('[NATIVE_MODEL_LOAD_FAILURE] path=$modelPath exception=$error');
        _log('[NATIVE_CONTEXT_FAILURE] path=$modelPath reason=ffi_exception');
        _log('[TERMINAL_STATE] state=failed reason=model_load_exception');
        clearRuntimeVerification();
        monitor.update(
          LocalRuntimeStatus.failed,
          message: 'Model load failed: $error',
        );
        _finishWithRuntimeError(
          controller,
          stage: 'model_load',
          message: 'Model load failed.',
          details: error.toString(),
        );
        return;
      }
      _log('[NATIVE_MODEL_LOAD_RESULT] llb_load_model returned: $loadResult');
      final loadedAfterLoad = bindings.isLoaded();
      _log('[NATIVE_MODEL_LOAD_RESULT] llb_is_loaded after load: $loadedAfterLoad');

      if (loadResult != 0) {
        final errMsg = _safeLastError(bindings);
        final lowerErr = errMsg.toLowerCase();
        if (lowerErr.contains('context')) {
          _log(
            '[NATIVE_CONTEXT_FAILURE] path=$modelPath code=$loadResult error=$errMsg',
          );
        }
        _log('[NATIVE_MODEL_LOAD_FAILURE] code=$loadResult error=$errMsg'
            ' path=$modelPath');
        _log('[TERMINAL_STATE] state=failed reason=model_load_error code=$loadResult');
        clearRuntimeVerification();
        monitor.update(LocalRuntimeStatus.failed, message: errMsg);
        _finishWithRuntimeError(
          controller,
          stage: 'model_load',
          message: 'Failed to load model.',
          details: 'Load failed with code $loadResult: $errMsg',
        );
        return;
      }
      _log('[NATIVE_MODEL_LOAD_SUCCESS] path=$modelPath modelId=$modelId'
          ' llb_is_loaded=$loadedAfterLoad');
      _log('[NATIVE_CONTEXT_CREATE] path=$modelPath status=ok');
      _logAi('model loaded');

      // ── Step 2: Start generation ─────────────────────────────────────────────
      final prompt = _composePrompt(request, modelId: modelId);
      final promptWordEstimate = prompt
          .trim()
          .split(RegExp(r'\s+'))
          .where((token) => token.isNotEmpty)
          .length;
      monitor.update(
        LocalRuntimeStatus.tokenizing,
        message: 'Tokenizing...',
        resetProgress: true,
      );
      _log(
        '[MODEL_EXECUTION] tokenization start prompt_chars=${prompt.length} prompt_word_estimate=$promptWordEstimate',
      );
      final maxTokens = request.maxTokens.clamp(1, _safeMaxTokens);
      if (request.maxTokens > _safeMaxTokens) {
        _log(
          '[MODEL_EXECUTION] requested max_tokens=${request.maxTokens} exceeds safe limit; clamped to $maxTokens',
        );
      }

      // Verify that the native model is actually loaded before calling
      // llb_start_gen so load failures are visible in logs before
      // generation starts.
      final loadedCheck = bindings.isLoaded();
      _log('[MODEL_EXECUTION] llb_is_loaded before start_generation: $loadedCheck');
      if (loadedCheck != 1) {
        clearRuntimeVerification();
        final nativeErr = _safeLastError(bindings);
        monitor.update(
          LocalRuntimeStatus.failed,
          message: 'Model not loaded (llb_is_loaded=$loadedCheck).',
        );
        _finishWithRuntimeError(
          controller,
          stage: 'start_generation',
          message:
              'Model is not loaded in the native runtime (llb_is_loaded=$loadedCheck).',
          details: nativeErr.isNotEmpty ? nativeErr : null,
        );
        return;
      }

      _log(
        '[MODEL_EXECUTION] Calling native llb_start_gen: prompt_chars=${prompt.length}'
        ' max_tokens=$maxTokens temperature=${request.temperature}',
      );
      _logAi('starting inference...');
      int startResult;
      final startupWatch = Stopwatch()..start();
      try {
        startResult = bindings.startGeneration(
          prompt,
          maxTokens,
          request.temperature,
        );
      } catch (error) {
        startupWatch.stop();
        clearRuntimeVerification();
        _safeResetRuntime(bindings, reason: 'start_generation_exception');
        monitor.update(LocalRuntimeStatus.failed,
            message: 'Native start_generation failed: $error');
        _finishWithRuntimeError(
          controller,
          stage: 'start_generation',
          message: 'Native generation start failed.',
          details: error.toString(),
        );
        return;
      }
      startupWatch.stop();
      _log('[MODEL_EXECUTION] llb_start_gen returned: $startResult');

      if (startupWatch.elapsed > _startGenerationTimeout) {
        _safeCancel(bindings);
        clearRuntimeVerification();
        _safeResetRuntime(bindings, reason: 'start_generation_timeout');
        monitor.update(
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
        clearRuntimeVerification();
        final err = _safeLastError(bindings);
        _safeResetRuntime(bindings, reason: 'start_generation_failed');
        monitor.update(LocalRuntimeStatus.failed, message: err);
        _finishWithRuntimeError(
          controller,
          stage: 'start_generation',
          message: 'Failed to start generation.',
          details: err,
        );
        return;
      }

      cancellationToken.onCancel(() => _safeCancel(bindings));

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
      monitor.update(
        LocalRuntimeStatus.inferencing,
        message: 'Generating',
        tokensGenerated: 0,
        elapsed: Duration.zero,
        startedAt: startedAt,
      );
      _logAi('streaming callback active');
      _log('[TOKEN_STREAM] loop start max_tokens=$maxTokens');

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
          if (cancellationToken.isCancelled) {
            _safeCancel(bindings);
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
            monitor.update(
              LocalRuntimeStatus.runtimeUnavailable,
              message: 'Cancelled',
              tokensGenerated: estimatedTokens,
              elapsed: DateTime.now().difference(startedAt),
            );
            break;
          }

          if (elapsed > _generationTimeout) {
            _safeCancel(bindings);
            clearRuntimeVerification();
            runtimeNeedsReset = true;
            runtimeResetReason = 'generation_timeout';
            _log(
              '[TERMINAL_STATE] state=timedOut reason=generation_timeout'
              ' generated_tokens=$estimatedTokens elapsed_ms=${elapsed.inMilliseconds}',
            );
            monitor.update(
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
          // Hard pre-inference watchdog (15 s): fires before the broader
          // _stalledInferenceTimeout so the exact failure stage is conclusively
          // logged before any generation loop timeout occurs.
          if (firstTokenAt == null && elapsed > _preInferenceTimeout) {
            _safeCancel(bindings);
            clearRuntimeVerification();
            runtimeNeedsReset = true;
            runtimeResetReason = 'stalled_pre_inference';
            _log(
              '[TERMINAL_STATE] state=stalled_pre_inference'
              ' elapsed_ms=${elapsed.inMilliseconds}'
              ' no_token_produced=true'
              ' modelId=$modelId'
              ' modelPath=$modelPath',
            );
            monitor.update(
              LocalRuntimeStatus.stalled,
              message: 'Runtime stalled before first token',
              tokensGenerated: estimatedTokens,
              elapsed: elapsed,
              startedAt: startedAt,
            );
            _logAi('stalled_pre_inference: no first token in ${_preInferenceTimeout.inSeconds}s');
            _finishWithRuntimeError(
              controller,
              stage: 'stalled_pre_inference',
              message:
                  'No first token produced within ${_preInferenceTimeout.inSeconds}s '
                  '(TERMINAL_STATE=stalled_pre_inference). '
                  'Likely failure: FFI open / symbol binding / GGUF path / native context.',
            );
            break;
          }
          if (firstTokenAt == null && elapsed > _stalledInferenceTimeout) {
            _safeCancel(bindings);
            clearRuntimeVerification();
            runtimeNeedsReset = true;
            runtimeResetReason = 'first_token_watchdog';
            _log(
              '[TERMINAL_STATE] state=stalled reason=first_token_watchdog'
              ' elapsed_ms=${elapsed.inMilliseconds} no_token_produced=true',
            );
            monitor.update(
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
              message: 'Local model stalled during inference.',
            );
            break;
          }
          if (firstTokenAt != null &&
              sinceLastTokenProgress > _noTokenProgressTimeout) {
            _safeCancel(bindings);
            clearRuntimeVerification();
            runtimeNeedsReset = true;
            runtimeResetReason = 'token_progress_watchdog';
            _log(
              '[TERMINAL_STATE] state=stalled reason=token_progress_watchdog'
              ' generated_tokens=$estimatedTokens'
              ' elapsed_ms=${elapsed.inMilliseconds}'
              ' since_last_token_ms=${sinceLastTokenProgress.inMilliseconds}',
            );
            monitor.update(
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
            _safeCancel(bindings);
            clearRuntimeVerification();
            runtimeNeedsReset = true;
            runtimeResetReason = 'poll_loop_watchdog';
            _log(
              '[TERMINAL_STATE] state=stalled reason=poll_loop_watchdog'
              ' idle_polls=$consecutiveIdlePolls generated_tokens=$estimatedTokens'
              ' elapsed_ms=${elapsed.inMilliseconds}',
            );
            monitor.update(
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
            status = bindings.pollToken(tokenBuf);
          } catch (error) {
            clearRuntimeVerification();
            runtimeNeedsReset = true;
            runtimeResetReason = 'poll_token_exception';
            monitor.update(
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

          if (status == 1) {
            String piece;
            try {
              piece = tokenBuf.toDartString();
            } catch (error) {
              consecutiveInvalidTokens++;
              if (consecutiveInvalidTokens >= _maxConsecutiveInvalidTokens) {
                _safeCancel(bindings);
                clearRuntimeVerification();
                runtimeNeedsReset = true;
                runtimeResetReason = 'token_decode_exception';
                _log(
                  '[TERMINAL_STATE] state=failed reason=token_decode_exception'
                  ' generated_tokens=$estimatedTokens'
                  ' error=$error',
                );
                monitor.update(
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
              if (isFirstToken) {
                _log(
                  '[FIRST_TOKEN] elapsed_ms=${streamingElapsed.inMilliseconds}'
                  ' token="${piece.replaceAll('\n', r'\n')}"'
                  ' token_count=$estimatedTokens',
                );
              }
              if (estimatedTokens % 16 == 0) {
                _log('[TOKEN_STREAM] token_count=$estimatedTokens');
              }
              _log(
                '[TOKEN_STREAM] piece token_index=$estimatedTokens text="${piece.replaceAll('\n', r'\n')}"'
                ' total_chars=${fullText.length} since_first_token_ms=${sinceFirstToken?.inMilliseconds ?? 0}',
              );
              if (piece == lastPiece) {
                repeatedTokenCount++;
                if (repeatedTokenCount >= _maxRepeatedTokenLoop) {
                  _safeCancel(bindings);
                  clearRuntimeVerification();
                  runtimeNeedsReset = true;
                  runtimeResetReason = 'repeated_token_loop';
                  _log(
                    '[TERMINAL_STATE] state=failed reason=repeated_token_loop'
                    ' generated_tokens=$estimatedTokens'
                    ' elapsed_ms=${streamingElapsed.inMilliseconds}',
                  );
                  monitor.update(
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
              monitor.update(
                LocalRuntimeStatus.streaming,
                message: 'Streaming',
                tokensGenerated: estimatedTokens,
                elapsed: streamingElapsed,
                startedAt: startedAt,
              );
              controller.add(InferenceResponse.token(text: piece, model: modelId));
            } else {
              consecutiveInvalidTokens++;
              _log(
                '[TOKEN_STREAM] empty token iteration=$pollIterations consecutive_empty=$consecutiveInvalidTokens',
              );
              if (consecutiveInvalidTokens >= _maxConsecutiveInvalidTokens) {
                _safeCancel(bindings);
                clearRuntimeVerification();
                runtimeNeedsReset = true;
                runtimeResetReason = 'empty_token_loop';
                _log(
                  '[TERMINAL_STATE] state=failed reason=empty_token_loop'
                  ' generated_tokens=$estimatedTokens'
                  ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}',
                );
                monitor.update(
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
            _log(
              '[FINAL_RESPONSE] eos generated_tokens=$estimatedTokens elapsed_ms=${completedElapsed.inMilliseconds}',
            );
            _log(
              '[TERMINAL_STATE] state=success generated_tokens=$estimatedTokens'
              ' elapsed_ms=${completedElapsed.inMilliseconds}',
            );
            _logAi('inference completed');
            controller.add(InferenceResponse.finalChunk(
              text: fullText.toString(),
              tokensGenerated: estimatedTokens,
              model: modelId,
            ));
            monitor.update(
              LocalRuntimeStatus.completed,
              message: 'Completed',
              tokensGenerated: estimatedTokens,
              elapsed: completedElapsed,
              startedAt: startedAt,
            );
            break;
          } else if (status == -99) {
            // Cancelled by the native thread.
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
            monitor.update(
              LocalRuntimeStatus.runtimeUnavailable,
              tokensGenerated: estimatedTokens,
              elapsed: DateTime.now().difference(startedAt),
            );
            break;
          } else if (status == -1) {
            clearRuntimeVerification();
            final err = _safeLastError(bindings);
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
              monitor.update(LocalRuntimeStatus.failed,
                  message: 'Out of memory: $err',
                  tokensGenerated: estimatedTokens,
                  elapsed: DateTime.now().difference(startedAt),
                  startedAt: startedAt);
            } else {
              monitor.update(
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
            terminalState == LocalRuntimeStatus.streaming ||
            terminalState == LocalRuntimeStatus.completed) {
          monitor.update(
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
          await controller.close();
        }
      }
      });
    }();

    return controller.stream;
  }

  // ── Private helpers ───────────────────────────────────────────────────────────

  Future<void> _runInferenceSerially(Future<void> Function() action) {
    final next = _inferenceTail.then((_) => action());
    _inferenceTail = next.catchError((_) {});
    return next;
  }

  static void _finishWithError(
    StreamController<InferenceResponse> ctrl,
    String message, {
    InferenceTerminalState state = InferenceTerminalState.failed,
  }) {
    if (ctrl.isClosed) return;
    ctrl.add(InferenceResponse.error(message, state: state));
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
        ctrl.add(InferenceResponse.notice(notice));
      }
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
      await ctrl.close();
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
  }) {
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

  static String _safeLastError(LlamaBridgeBindings bindings) {
    try {
      final value = bindings.lastError();
      if (value.trim().isEmpty) return 'Unknown native runtime error.';
      _log('[MODEL_EXECUTION] native error: $value');
      return value;
    } catch (error) {
      _log('[MODEL_EXECUTION] llb_last_error failed: $error');
      return 'Native runtime error (unable to read details).';
    }
  }

  static void _safeCancel(LlamaBridgeBindings bindings) {
    try {
      bindings.cancel();
    } catch (error) {
      _log('[MODEL_EXECUTION] llb_cancel failed: $error');
    }
  }

  static void _safeResetRuntime(
    LlamaBridgeBindings bindings, {
    required String reason,
  }) {
    try {
      _log('[MODEL_EXECUTION] resetting native runtime: $reason');
      _log('[MODEL_EXECUTION] llb_is_loaded before reset: ${bindings.isLoaded()}');
      bindings.cancel();
      bindings.freeModel();
      _log('[MODEL_EXECUTION] llb_is_loaded after reset: ${bindings.isLoaded()}');
    } catch (error) {
      _log('[MODEL_EXECUTION] runtime reset failed: $error');
    }
  }

  static void _log(String message) {
    debugPrint('[$_logTag] $message');
  }

  static void _logAi(String message) {
    debugPrint('[AI] $message');
  }

}
