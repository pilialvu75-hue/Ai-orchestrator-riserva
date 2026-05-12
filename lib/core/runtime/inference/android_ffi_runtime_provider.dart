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
  static const Duration _generationTimeout = Duration(seconds: 200);
  // If native polling produces no token at all within this window, treat the
  // run as stalled rather than waiting for the full timeout budget.
  // Keep this aligned with native/android/llama_bridge.cpp kNoTokenStallMillis.
  static const Duration _stalledInferenceTimeout = Duration(seconds: 45);
  static const Duration _startGenerationTimeout = Duration(seconds: 60);
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
      'Library loaded: ${LlamaFfiLoader.bridgeLibraryName}'
      ' abi=${LlamaFfiLoader.currentAbiName}',
    );
    return true;
  }

  @override
  Future<LocalRuntimeState> validateRuntime({AiModel? selectedModel}) async {
    if (!LlamaFfiLoader.isCurrentPlatformSupported) {
      return LocalRuntimeState(
        status: LocalRuntimeStatus.runtimeFailed,
        message:
            'Unsupported Android ABI (${LlamaFfiLoader.currentAbiName}). '
            'Only ${LlamaFfiLoader.supportedAbiNames} builds are supported.',
      );
    }
    if (!_ensureLibraryLoaded()) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.missingLibrary,
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
        );
        return;
      }
      final modelPath = request.modelPath;
      final modelId = request.modelId;

      if (modelPath == null || modelPath.isEmpty || modelId == null) {
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

      if (!_androidSafeModelIds.contains(modelId)) {
        const unsupportedAndroidModelMessage =
            'Selected model is not enabled for Android local runtime. '
            'Use DeepSeek-R1-Distill-Qwen-1.5B, Qwen3-1.7B, '
            'gemma-2-2b-it, llama_1b, or gemma_2b.';
        monitor.update(
          LocalRuntimeStatus.runtimeFailed,
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
        monitor.update(LocalRuntimeStatus.runtimeFailed, message: modelValidationError);
        _finishWithRuntimeError(
          controller,
          stage: 'model_validation',
          message: modelValidationError,
        );
        return;
      }

      if (!_ensureLibraryLoaded()) {
        monitor.update(
          LocalRuntimeStatus.missingLibrary,
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
      _log('Model load start: modelId=$modelId path=$modelPath n_ctx=512 threads=2');

      int loadResult;
      try {
        loadResult = bindings.loadModel(modelPath);
      } catch (error) {
        monitor.update(
          LocalRuntimeStatus.runtimeFailed,
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
      _log('llb_load_model returned: $loadResult');
      final loadedAfterLoad = bindings.isLoaded();
      _log('llb_is_loaded after model_load: $loadedAfterLoad');

      if (loadResult != 0) {
        final errMsg = _safeLastError(bindings);
        monitor.update(LocalRuntimeStatus.runtimeFailed, message: errMsg);
        _finishWithRuntimeError(
          controller,
          stage: 'model_load',
          message: 'Failed to load model.',
          details: 'Load failed with code $loadResult: $errMsg',
        );
        return;
      }
      _log('Model load end: modelId=$modelId');
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
        'Tokenization step start: prompt_chars=${prompt.length} prompt_word_estimate=$promptWordEstimate',
      );
      final maxTokens = request.maxTokens.clamp(1, _safeMaxTokens);
      if (request.maxTokens > _safeMaxTokens) {
        _log(
          'Requested max_tokens=${request.maxTokens} exceeds safe limit; clamped to $maxTokens',
        );
      }

      // Verify that the native model is actually loaded before calling
      // llb_start_gen so load failures are visible in logs before
      // generation starts.
      final loadedCheck = bindings.isLoaded();
      _log('llb_is_loaded before start_generation: $loadedCheck');
      if (loadedCheck != 1) {
        final nativeErr = _safeLastError(bindings);
        monitor.update(
          LocalRuntimeStatus.runtimeFailed,
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
        'Calling native llb_start_gen: prompt_chars=${prompt.length}'
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
        _safeResetRuntime(bindings, reason: 'start_generation_exception');
        monitor.update(LocalRuntimeStatus.runtimeFailed,
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
      _log('llb_start_gen returned: $startResult');

      if (startupWatch.elapsed > _startGenerationTimeout) {
        _safeCancel(bindings);
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
        final err = _safeLastError(bindings);
        _safeResetRuntime(bindings, reason: 'start_generation_failed');
        monitor.update(LocalRuntimeStatus.runtimeFailed, message: err);
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
      var runtimeNeedsReset = false;
      String? runtimeResetReason;
      monitor.update(
        LocalRuntimeStatus.inferring,
        message: 'Generating',
        tokensGenerated: 0,
        elapsed: Duration.zero,
        startedAt: startedAt,
      );
      _logAi('streaming callback active');
      _log('Inference loop start: max_tokens=$maxTokens');

      try {
        while (true) {
          pollIterations++;
          final elapsed = DateTime.now().difference(startedAt);
          final sinceFirstToken =
              firstTokenAt == null ? null : DateTime.now().difference(firstTokenAt);
          _log(
            'Poll iteration=$pollIterations tokens=$estimatedTokens elapsed_ms=${elapsed.inMilliseconds}',
          );
          if (cancellationToken.isCancelled) {
            _safeCancel(bindings);
            _finishWithRuntimeError(
              controller,
              stage: 'cancelled',
              message: 'Inference cancelled.',
            );
            monitor.update(
              LocalRuntimeStatus.ready,
              message: 'Cancelled',
              tokensGenerated: estimatedTokens,
              elapsed: DateTime.now().difference(startedAt),
            );
            break;
          }

          if (elapsed > _generationTimeout) {
            _safeCancel(bindings);
            runtimeNeedsReset = true;
            runtimeResetReason = 'generation_timeout';
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
            );
            break;
          }
          if (firstTokenAt == null && elapsed > _stalledInferenceTimeout) {
            _safeCancel(bindings);
            runtimeNeedsReset = true;
            runtimeResetReason = 'first_token_watchdog';
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

          int status;
          try {
            status = bindings.pollToken(tokenBuf);
          } catch (error) {
            runtimeNeedsReset = true;
            runtimeResetReason = 'poll_token_exception';
            monitor.update(
              LocalRuntimeStatus.runtimeFailed,
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
          _log('Poll status iteration=$pollIterations status=$status');

          if (status == 1) {
            String piece;
            try {
              piece = tokenBuf.toDartString();
            } catch (error) {
              consecutiveInvalidTokens++;
              if (consecutiveInvalidTokens >= _maxConsecutiveInvalidTokens) {
                _safeCancel(bindings);
                runtimeNeedsReset = true;
                runtimeResetReason = 'token_decode_exception';
                monitor.update(
                  LocalRuntimeStatus.runtimeFailed,
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
              firstTokenAt ??= DateTime.now();
              consecutiveInvalidTokens = 0;
              fullText.write(piece);
              estimatedTokens++;
              final streamingElapsed = DateTime.now().difference(startedAt);
              if (estimatedTokens % 16 == 0) {
                _log('Generated token count: $estimatedTokens');
              }
              _log(
                'Generated piece token_index=$estimatedTokens text="${piece.replaceAll('\n', r'\n')}"'
                ' total_chars=${fullText.length} since_first_token_ms=${sinceFirstToken?.inMilliseconds ?? 0}',
              );
              if (piece == lastPiece) {
                repeatedTokenCount++;
                if (repeatedTokenCount >= _maxRepeatedTokenLoop) {
                  _safeCancel(bindings);
                  runtimeNeedsReset = true;
                  runtimeResetReason = 'repeated_token_loop';
                  monitor.update(
                    LocalRuntimeStatus.runtimeFailed,
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
                'Empty token detected iteration=$pollIterations consecutive_empty=$consecutiveInvalidTokens',
              );
              if (consecutiveInvalidTokens >= _maxConsecutiveInvalidTokens) {
                _safeCancel(bindings);
                runtimeNeedsReset = true;
                runtimeResetReason = 'empty_token_loop';
                monitor.update(
                  LocalRuntimeStatus.runtimeFailed,
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
            _log(
              'EOS detected. generated_tokens=$estimatedTokens elapsed_ms=${completedElapsed.inMilliseconds}',
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
            _finishWithRuntimeError(
              controller,
              stage: 'cancelled',
              message: 'Inference cancelled.',
            );
            monitor.update(
              LocalRuntimeStatus.ready,
              tokensGenerated: estimatedTokens,
              elapsed: DateTime.now().difference(startedAt),
            );
            break;
          } else if (status == -1) {
            final err = _safeLastError(bindings);
            final statusLower = err.toLowerCase();
            runtimeNeedsReset = true;
            runtimeResetReason = 'native_error';
            if (statusLower.contains('out of memory') ||
                statusLower.contains('oom') ||
                statusLower.contains('memory')) {
              monitor.update(LocalRuntimeStatus.runtimeFailed,
                  message: 'Out of memory: $err',
                  tokensGenerated: estimatedTokens,
                  elapsed: DateTime.now().difference(startedAt),
                  startedAt: startedAt);
            } else {
              monitor.update(
                LocalRuntimeStatus.runtimeFailed,
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
        if (terminalState == LocalRuntimeStatus.loading ||
            terminalState == LocalRuntimeStatus.tokenizing ||
            terminalState == LocalRuntimeStatus.inferring ||
            terminalState == LocalRuntimeStatus.streaming) {
          monitor.update(
            LocalRuntimeStatus.ready,
            message: 'Runtime ready for the next prompt.',
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
    String message,
  ) {
    if (ctrl.isClosed) return;
    ctrl.add(InferenceResponse.error(message));
    ctrl.close();
  }

  static void _finishWithRuntimeError(
    StreamController<InferenceResponse> ctrl, {
    required String stage,
    required String message,
    String? details,
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
    _finishWithError(ctrl, payload);
  }

  static Future<void> _finishWithPartialOrRuntimeError(
    StreamController<InferenceResponse> ctrl, {
    required String stage,
    required String message,
    required String modelId,
    required String fullText,
    required int tokensGenerated,
    String? notice,
  }) async {
    if (ctrl.isClosed) return;
    if (fullText.trim().isNotEmpty) {
      if (notice != null && notice.trim().isNotEmpty) {
        ctrl.add(InferenceResponse.notice(notice));
      }
      ctrl.add(
        InferenceResponse.finalChunk(
          text: fullText,
          tokensGenerated: tokensGenerated,
          model: modelId,
        ),
      );
      await ctrl.close();
      return;
    }
    _finishWithRuntimeError(
      ctrl,
      stage: stage,
      message: message,
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
      _log('Native error: $value');
      return value;
    } catch (error) {
      _log('llb_last_error failed: $error');
      return 'Native runtime error (unable to read details).';
    }
  }

  static void _safeCancel(LlamaBridgeBindings bindings) {
    try {
      bindings.cancel();
    } catch (error) {
      _log('llb_cancel failed: $error');
    }
  }

  static void _safeResetRuntime(
    LlamaBridgeBindings bindings, {
    required String reason,
  }) {
    try {
      _log('Resetting native runtime: $reason');
      _log('llb_is_loaded before reset: ${bindings.isLoaded()}');
      bindings.cancel();
      bindings.freeModel();
      _log('llb_is_loaded after reset: ${bindings.isLoaded()}');
    } catch (error) {
      _log('Runtime reset failed: $error');
    }
  }

  static void _log(String message) {
    debugPrint('[$_logTag] $message');
  }

  static void _logAi(String message) {
    debugPrint('[AI] $message');
  }

}
