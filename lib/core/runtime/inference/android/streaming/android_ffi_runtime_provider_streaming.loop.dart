part of runtime_core;

extension _AndroidFfiRuntimePollingExtension on AndroidFfiRuntimeProvider {
  
  Future<void> _executeStreamingPollingLoop({
    required StreamController<InferenceResponse> controller,
    required dynamic bindings,
    required int nativeSessionId,
    required InferenceRequest request,
    required String modelId,
    required String modelPath,
    required String sessionId,
    required String dartThreadId,
    required String attemptId,
    required int maxTokens,
    required Duration firstTokenDeadline,
    required bool isForensicSelfTest,
    required VoidCallback freePromptNativePtr,
    required Function classifyFirstTokenTermination,
    required int pollIterations,
    required DateTime? firstTokenAt,
    required int estimatedTokens,
    required bool runtimeNeedsReset,
    required String? runtimeResetReason,
  }) async {
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
        if (controller.isClosed) {
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
          final localSinceFirstToken = sinceFirstToken;
          AndroidFfiRuntimeProvider._log(
            '[TOKEN_STREAM] piece token_index=$estimatedTokens text="${sanitizedPiece.replaceAll('\n', r'\n')}"'
            ' total_chars=${fullText.length} since_first_token_ms=${localSinceFirstToken?.inMilliseconds ?? 0}',
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
          consecutiveIdlePolls++;
          if (consecutiveIdlePolls % 120 == 0) {
            _throttledLoopLog(
              '[TOKEN_STREAM] idle polling continues: idle_polls=$consecutiveIdlePolls '
              'idle_ms=${DateTime.now().difference(lastTokenProgressAt).inMilliseconds}',
            );
          }
          
          if (_preFirstTokenActive) {
            await Future<void>.delayed(Duration.zero);
          } else {
            _increaseIdleBackoff();
            await Future<void>.delayed(Duration(milliseconds: _idleBackoffMs));
          }
        }
      }
    } finally {
      calloc.free(tokenBufRaw);
    }
  }
}
