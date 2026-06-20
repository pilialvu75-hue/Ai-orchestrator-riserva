/// Layer di Streaming e Polling per il Runtime Android FFI.
/// 
/// Gestisce il ciclo vitale di estrazione dei token dal thread C++ nativo,
/// implementa i watchdog di sicurezza asincroni e garantisce l'isolamento
/// dei guasti per evitare corruzioni della KV Cache in modelli sensibili come Phi-3.5.
part of '../../runtime_core.dart';

class _PollingState {
  _PollingState()
      : startedAt = DateTime.now(),
        lastTokenProgressAt = DateTime.now(),
        lastNativeActivityAt = DateTime.now();

  final DateTime startedAt;
  int repeatedTokenCount = 0;
  int consecutiveInvalidTokens = 0;
  String? lastPiece;
  final StringBuffer fullText = StringBuffer();
  DateTime lastTokenProgressAt;
  DateTime lastNativeActivityAt;
  int consecutiveIdlePolls = 0;
  bool firstPollBoundaryLogged = false;
  bool firstPollBoundaryFinished = false;
}

extension AndroidFfiRuntimePollingExtension on AndroidFfiRuntimeProvider {
  Future<void> _runTokenPollingLoop({
    required _GenerationStartupState startup,
    required _FirstTokenAttemptState attemptState,
    required _StreamFlowControlState flowState,
  }) async {
    final controller = startup.controller;
    final cancellationToken = startup.cancellationToken;
    final bindings = startup.bindings;
    final sessionId = startup.sessionId;
    final modelId = startup.modelId;
    final modelPath = startup.modelPath;
    final nativeSessionId = startup.nativeSessionId;
    final isForensicSelfTest = startup.isForensicSelfTest;
    final dartThreadId = startup.dartThreadId;
    final firstTokenDeadline = startup.firstTokenDeadline;
    
    final state = _PollingState();
    final tokenBufRaw = calloc<Uint8>(LlamaNativeDefaults.tokenBufferSize);
    final tokenBuf = tokenBufRaw.cast<Utf8>();
    
    try {
      _setPhase(RuntimePhase.waitingFirstToken);
      _updateRuntimeStatus(
        LocalRuntimeStatus.inferencing,
        message: 'Generating',
        tokensGenerated: 0,
        elapsed: Duration.zero,
        startedAt: state.startedAt,
      );
      
      AndroidFfiRuntimeProvider._logAi('streaming callback active');
      AndroidFfiRuntimeProvider._log('[STREAM_ADD] event=generation_started session=$sessionId');
      AndroidFfiRuntimeProvider._log('[TOKEN_STREAM] loop start max_tokens=${startup.maxTokens}');
      AndroidFfiRuntimeProvider._log('[TOKEN_LOOP] phase=start max_tokens=${startup.maxTokens}');
      AndroidFfiRuntimeProvider._log('[FFI_PRE_POLL] session=$sessionId native_session=$nativeSessionId');
      AndroidFfiRuntimeProvider._log('[FFI_POLL_BEGIN] session=$nativeSessionId');
      
      _preFirstTokenActive = true;
      _setPhase(RuntimePhase.waitingFirstToken);
      
      AndroidFfiRuntimeProvider._log(
        '[FIRST_TOKEN_POLL_LOOP_BEGIN] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
        ' sessionId=$sessionId nativeSessionId=$nativeSessionId phase=$_currentFfiPhase'
        ' pre_first_token_active=true max_tokens=${startup.maxTokens}',
      );

      while (true) {
        attemptState.pollIterations++;
        
        // Yield ottimizzato dell'Isolate: spaziato a 100 iterazioni anziché 50
        // e ancorato a Duration.zero per non impattare sul throughput nativo.
        if (attemptState.pollIterations % 100 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        
        final now = DateTime.now();
        final elapsed = now.difference(state.startedAt);
        final sinceFirstToken = attemptState.firstTokenAt == null
            ? null
            : now.difference(attemptState.firstTokenAt!);
        final sinceLastTokenProgress = now.difference(state.lastTokenProgressAt);
        
        _throttledLoopLog(
          '[TOKEN_STREAM] poll iteration=${attemptState.pollIterations} tokens=${attemptState.estimatedTokens} elapsed_ms=${elapsed.inMilliseconds}'
          ' idle_ms=${sinceLastTokenProgress.inMilliseconds} idle_polls=${state.consecutiveIdlePolls} phase=$_currentFfiPhase',
        );
        _throttledLoopLog(
          '[TOKEN_LOOP] iteration=${attemptState.pollIterations} tokens=${attemptState.estimatedTokens} elapsed_ms=${elapsed.inMilliseconds}',
        );
        _throttledLoopLog(
          '[GENERATION_STEP] iteration=${attemptState.pollIterations} elapsed_ms=${elapsed.inMilliseconds}'
          ' generated_tokens=${attemptState.estimatedTokens}',
        );
        _throttledLoopLog(
          '[GENERATION_ALIVE] iteration=${attemptState.pollIterations} elapsed_ms=${elapsed.inMilliseconds} first_token=${attemptState.firstTokenAt != null}',
        );
        
        if (attemptState.firstTokenAt == null && attemptState.pollIterations % 25 == 0) {
          AndroidFfiRuntimeProvider._log('[FIRST_TOKEN_WAIT] iteration=${attemptState.pollIterations} waited_ms=${elapsed.inMilliseconds}');
        }
        
        // ---------------------------------------------------------------------
        // WATCHDOG 1: Cancellazione Esplicita Richiesta dall'Utente o UI scollegata
        // ---------------------------------------------------------------------
        if (cancellationToken.isCancelled || controller.isClosed) {
          _classifyFirstTokenTermination(
            flowState: flowState,
            attemptState: attemptState,
            reason: 'poll_cancellation',
            boundary: 'poll_loop',
            cancellation: true,
          );
          _safeCancel(bindings, nativeSessionId);
          clearRuntimeVerification();
          AndroidFfiRuntimeProvider._log(
            '[TERMINAL_STATE] state=cancelled generated_tokens=${attemptState.estimatedTokens}'
            ' elapsed_ms=${DateTime.now().difference(state.startedAt).inMilliseconds}',
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
            tokensGenerated: attemptState.estimatedTokens,
            elapsed: DateTime.now().difference(state.startedAt),
          );
          AndroidFfiRuntimeProvider._log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=pre_poll_cancellation');
          break;
        }
        
        // ---------------------------------------------------------------------
        // WATCHDOG 2: Timeout di Generazione Globale
        // ---------------------------------------------------------------------
        if (elapsed > AndroidFfiRuntimeProvider._generationTimeout) {
          _classifyFirstTokenTermination(
            flowState: flowState,
            attemptState: attemptState,
            reason: attemptState.firstTokenAt == null
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
          attemptState.runtimeNeedsReset = true;
          attemptState.runtimeResetReason = 'generation_timeout';
          
          if (attemptState.firstTokenAt == null) {
            AndroidFfiRuntimeProvider._log(
              '[FIRST_TOKEN_FAILURE] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
              ' sessionId=$sessionId reason=generation_timeout_no_first_token'
              ' elapsed_ms=${elapsed.inMilliseconds}'
              ' timeout_ms=${AndroidFfiRuntimeProvider._generationTimeout.inMilliseconds}'
              ' poll_iterations=${attemptState.pollIterations}',
            );
          }
          AndroidFfiRuntimeProvider._log(
            '[TERMINAL_STATE] state=timedOut reason=generation_timeout'
            ' generated_tokens=${attemptState.estimatedTokens} elapsed_ms=${elapsed.inMilliseconds}',
          );
          _updateRuntimeStatus(
            LocalRuntimeStatus.timedOut,
            message: 'Timed out',
            tokensGenerated: attemptState.estimatedTokens,
            elapsed: elapsed,
            startedAt: state.startedAt,
          );
          AndroidFfiRuntimeProvider._logAi('inference timeout');
          final partialText = _flushStructuralTemplateOutput(state.fullText);
          await AndroidFfiRuntimeProvider._finishWithPartialOrRuntimeError(
            controller,
            stage: 'timeout',
            message: 'Local generation timed out.',
            modelId: modelId,
            fullText: partialText,
            tokensGenerated: attemptState.estimatedTokens,
            notice: 'Local model timed out after ${elapsed.inSeconds}s. Returning partial response.',
            partialTerminalState: InferenceTerminalState.timeout,
          );
          break;
        }
        
        // ---------------------------------------------------------------------
        // WATCHDOG 3: Latenza di Risposta sul Primo Token (Hot-Path)
        // ---------------------------------------------------------------------
        final firstTokenWaitElapsed = now.difference(state.lastNativeActivityAt);
        if (attemptState.firstTokenAt == null &&
            firstTokenWaitElapsed.inMilliseconds > firstTokenDeadline.inMilliseconds) {
          _classifyFirstTokenTermination(
            flowState: flowState,
            attemptState: attemptState,
            reason: 'first_token_watchdog',
            boundary: 'poll_loop',
            runtimeReset: true,
          );
          _setPhase(RuntimePhase.stalled);
          await _handleFirstTokenWatchdogTimeout(
            flowState: flowState,
            attemptState: attemptState,
            controller: controller,
            bindings: bindings,
            sessionKey: sessionId,
            modelId: modelId,
            nativeSessionHandle: nativeSessionId,
            startedAt: state.startedAt,
            firstTokenDeadline: firstTokenDeadline,
            dartThreadId: dartThreadId,
            isForensicSelfTest: isForensicSelfTest,
          );
          break;
        }
        
        // ---------------------------------------------------------------------
        // WATCHDOG 4: Assenza di Avanzamento del Flusso di Token Nativi
        // ---------------------------------------------------------------------
        if (attemptState.firstTokenAt != null &&
            sinceLastTokenProgress > AndroidFfiRuntimeProvider._noTokenProgressTimeout) {
          _classifyFirstTokenTermination(
            flowState: flowState,
            attemptState: attemptState,
            reason: 'token_progress_watchdog',
            boundary: 'poll_loop',
            runtimeReset: true,
          );
          _setPhase(RuntimePhase.stalled);
          _safeCancel(bindings, nativeSessionId);
          clearRuntimeVerification();
          attemptState.runtimeNeedsReset = true;
          attemptState.runtimeResetReason = 'token_progress_watchdog';
          
          AndroidFfiRuntimeProvider._log(
            '[STALL] reason=token_progress_watchdog'
            ' generated_tokens=${attemptState.estimatedTokens}'
            ' elapsed_ms=${elapsed.inMilliseconds}'
            ' since_last_token_ms=${sinceLastTokenProgress.inMilliseconds}'
            ' session=$sessionId',
          );
          AndroidFfiRuntimeProvider._log(
            '[TERMINAL_STATE] state=stalled reason=token_progress_watchdog'
            ' generated_tokens=${attemptState.estimatedTokens}'
            ' elapsed_ms=${elapsed.inMilliseconds}'
            ' since_last_token_ms=${sinceLastTokenProgress.inMilliseconds}',
          );
          _updateRuntimeStatus(
            LocalRuntimeStatus.stalled,
            message: 'Token stream stalled',
            tokensGenerated: attemptState.estimatedTokens,
            elapsed: elapsed,
            startedAt: state.startedAt,
          );
          
          final partialText = _flushStructuralTemplateOutput(state.fullText);
          await AndroidFfiRuntimeProvider._finishWithPartialOrRuntimeError(
            controller,
            stage: 'stalled',
            message: 'Token stream stalled during local inference.',
            modelId: modelId,
            fullText: partialText,
            tokensGenerated: attemptState.estimatedTokens,
            notice: 'Token stream stalled after ${sinceLastTokenProgress.inSeconds}s. Returning partial response.',
            partialTerminalState: InferenceTerminalState.timeout,
          );
          break;
        }
        
        // ---------------------------------------------------------------------
        // WATCHDOG 5: Raggiungimento Limite Iterazioni Polling a Vuoto (Hard Cap)
        // ---------------------------------------------------------------------
        if (_pollingController.isIdleLimitReached(state.consecutiveIdlePolls)) {
          debugPrint(
            '[TOKEN_STREAM] Hard cap reached: consecutiveIdlePolls >= ${_pollingController.maxIdlePollIterations}. Aborting loop.',
          );
          _classifyFirstTokenTermination(
            flowState: flowState,
            attemptState: attemptState,
            reason: 'poll_loop_watchdog',
            boundary: 'poll_loop',
            runtimeReset: true,
          );
          _setPhase(RuntimePhase.stalled);
          _safeCancel(bindings, nativeSessionId);
          clearRuntimeVerification();
          attemptState.runtimeNeedsReset = true;
          attemptState.runtimeResetReason = 'poll_loop_watchdog';
          
          AndroidFfiRuntimeProvider._log(
            '[STREAM_TIMEOUT] reason=poll_loop_idle idle_polls=${state.consecutiveIdlePolls}'
            ' elapsed_ms=${elapsed.inMilliseconds} session=$sessionId',
          );
          AndroidFfiRuntimeProvider._log(
            '[STALL] reason=poll_loop_watchdog'
            ' idle_polls=${state.consecutiveIdlePolls} generated_tokens=${attemptState.estimatedTokens}'
            ' elapsed_ms=${elapsed.inMilliseconds} session=$sessionId',
          );
          AndroidFfiRuntimeProvider._log(
            '[TERMINAL_STATE] state=stalled reason=poll_loop_watchdog'
            ' idle_polls=${state.consecutiveIdlePolls} generated_tokens=${attemptState.estimatedTokens}'
            ' elapsed_ms=${elapsed.inMilliseconds}',
          );
          _updateRuntimeStatus(
            LocalRuntimeStatus.stalled,
            message: 'Polling loop stalled',
            tokensGenerated: attemptState.estimatedTokens,
            elapsed: elapsed,
            startedAt: state.startedAt,
          );
          
          final partialText = _flushStructuralTemplateOutput(state.fullText);
          await AndroidFfiRuntimeProvider._finishWithPartialOrRuntimeError(
            controller,
            stage: 'poll_loop',
            message: 'Token polling stalled in local runtime.',
            modelId: modelId,
            fullText: partialText,
            tokensGenerated: attemptState.estimatedTokens,
            notice: 'No token progress detected in polling loop. Returning partial response.',
            partialTerminalState: InferenceTerminalState.timeout,
          );
          break;
        }
        
        // ---------------------------------------------------------------------
        // ESECUZIONE DEL COUPLING NATIVO FFI: Estrazione del token
        // ---------------------------------------------------------------------
        int status;
        try {
          _throttledLoopLog(
            '[FFI_POLL_BEGIN] entering pollToken session=$nativeSessionId '
            'iteration=${attemptState.pollIterations} phase=$_currentFfiPhase',
          );
          
          if (!state.firstPollBoundaryLogged) {
            state.firstPollBoundaryLogged = true;
            final pollHandleHex = '0x${nativeSessionId.toUnsigned(64).toRadixString(16)}';
            final pollHandleAddress = nativeSessionId > 0 ? Pointer<Void>.fromAddress(nativeSessionId).address : 0;
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
            '[FFI_CALLBACK_ENTER] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 poll_iteration=${attemptState.pollIterations}',
          );
          
          status = bindings.pollToken(nativeSessionId, tokenBuf);
          
          if (!state.firstPollBoundaryFinished) {
            state.firstPollBoundaryFinished = true;
            final pollHandleHex = '0x${nativeSessionId.toUnsigned(64).toRadixString(16)}';
            final pollHandleAddress = nativeSessionId > 0 ? Pointer<Void>.fromAddress(nativeSessionId).address : 0;
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
          _classifyFirstTokenTermination(
            flowState: flowState,
            attemptState: attemptState,
            reason: 'poll_token_exception',
            boundary: 'poll_token',
            exception: true,
            runtimeReset: true,
          );
          clearRuntimeVerification();
          attemptState.runtimeNeedsReset = true;
          attemptState.runtimeResetReason = 'poll_token_exception';
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
        
        _throttledLoopLog('[TOKEN_STREAM] poll status iteration=${attemptState.pollIterations} status=$status');
        AndroidFfiRuntimeProvider._log(
          '[FFI_CALLBACK_PAYLOAD] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 poll_iteration=${attemptState.pollIterations} status=$status',
        );
        
        // STATUS 1: Token estratto correttamente con payload valido
        if (status == 1) {
          String piece;
          try {
            piece = tokenBuf.toDartString();
          } catch (error) {
            AndroidFfiRuntimeProvider._log('[TOKENIZER_DECODE_FAIL] stage=dart_utf8_decode error=$error');
            state.consecutiveInvalidTokens++;
            if (state.consecutiveInvalidTokens >= AndroidFfiRuntimeProvider._maxConsecutiveInvalidTokens) {
              _classifyFirstTokenTermination(
                flowState: flowState,
                attemptState: attemptState,
                reason: 'token_decode_exception',
                boundary: 'token_decode',
                exception: true,
                runtimeReset: true,
              );
              _safeCancel(bindings, nativeSessionId);
              clearRuntimeVerification();
              attemptState.runtimeNeedsReset = true;
              attemptState.runtimeResetReason = 'token_decode_exception';
              AndroidFfiRuntimeProvider._log(
                '[TERMINAL_STATE] state=failed reason=token_decode_exception'
                ' generated_tokens=${attemptState.estimatedTokens} error=$error',
              );
              _updateRuntimeStatus(
                LocalRuntimeStatus.failed,
                message: 'Invalid generated token stream.',
                tokensGenerated: attemptState.estimatedTokens,
                elapsed: DateTime.now().difference(state.startedAt),
                startedAt: state.startedAt,
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
          state.lastNativeActivityAt = tokenObservedAt;
          
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
          
          // Reattività ripristinata: Reset del backoff a 0ms (hot-path) alla ricezione del token
          _pollingController.resetIdleBackoff();
          
          final isFirstToken = attemptState.firstTokenAt == null;
          DateTime? firstTokenTimestamp;
          if (isFirstToken && _preFirstTokenActive) {
            firstTokenTimestamp = _handleFirstTokenIfNeeded(sanitizedPiece);
            if (firstTokenTimestamp != null) {
              attemptState.firstTokenAt = firstTokenTimestamp;
            }
          }
          
          final firstTokenReceived = firstTokenTimestamp != null;
          state.consecutiveInvalidTokens = 0;
          state.consecutiveIdlePolls = 0;
          state.lastTokenProgressAt = tokenObservedAt;
          state.fullText.write(sanitizedPiece);
          attemptState.estimatedTokens++;
          recordVerificationSuccess(modelPath: modelPath, source: 'first_token');
          
          final streamingElapsed = DateTime.now().difference(state.startedAt);
          
          AndroidFfiRuntimeProvider._log(
            '[FFI_CALLBACK_PAYLOAD] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} poll_iteration=${attemptState.pollIterations} status=$status',
          );
          AndroidFfiRuntimeProvider._log(
            '[DART_STREAM_RECEIVE] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} poll_iteration=${attemptState.pollIterations} subscription_alive=${!controller.isClosed}',
          );
          
          if (firstTokenReceived) {
            startup.freePromptNativePtr();
            _logFirstTokenSuccessTelemetry(
              attemptState: attemptState,
              sessionKey: sessionId,
              nativeSessionHandle: nativeSessionId,
              dartThreadId: dartThreadId,
              sanitizedPiece: sanitizedPiece,
              pollIterations: attemptState.pollIterations,
              estimatedTokens: attemptState.estimatedTokens,
              elapsed: streamingElapsed,
            );
          }
          
          AndroidFfiRuntimeProvider._log(
            '[DART_TOKEN_RECEIVED] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} queue_size=-1 poll_iteration=${attemptState.pollIterations}',
          );
          AndroidFfiRuntimeProvider._log('[FFI_TOKEN] session=$nativeSessionId chars=${sanitizedPiece.length}');
          
          if (attemptState.estimatedTokens % 16 == 0) {
            AndroidFfiRuntimeProvider._log('[TOKEN_STREAM] token_count=${attemptState.estimatedTokens}');
          }
          
          AndroidFfiRuntimeProvider._log(
            '[TOKEN_STREAM] piece token_index=${attemptState.estimatedTokens} text="${sanitizedPiece.replaceAll('\n', r'\n')}"'
            ' total_chars=${state.fullText.length} since_first_token_ms=${sinceFirstToken?.inMilliseconds ?? 0}',
          );
          AndroidFfiRuntimeProvider._log('[TOKEN_EVAL] token_index=${attemptState.estimatedTokens} elapsed_ms=${streamingElapsed.inMilliseconds}');
          AndroidFfiRuntimeProvider._log(
            '[TOKEN_DECODE] token_index=${attemptState.estimatedTokens} chars=${sanitizedPiece.length}'
            ' text="${sanitizedPiece.replaceAll('\n', r'\n')}"',
          );
          
          // Prevenzione Loop Allucinatori Ciclici di Token Identici
          if (sanitizedPiece == state.lastPiece) {
            state.repeatedTokenCount++;
            if (state.repeatedTokenCount >= AndroidFfiRuntimeProvider._maxRepeatedTokenLoop) {
              _classifyFirstTokenTermination(
                flowState: flowState,
                attemptState: attemptState,
                reason: 'repeated_token_loop',
                boundary: 'generation_loop',
                runtimeReset: true,
              );
              _safeCancel(bindings, nativeSessionId);
              clearRuntimeVerification();
              attemptState.runtimeNeedsReset = true;
              attemptState.runtimeResetReason = 'repeated_token_loop';
              _setPhase(RuntimePhase.failed);
              
              AndroidFfiRuntimeProvider._log(
                '[STREAM_LOOP] reason=repeated_token'
                ' count=${state.repeatedTokenCount} token="${sanitizedPiece.replaceAll('\n', r'\n')}"'
                ' generated_tokens=${attemptState.estimatedTokens} session=$sessionId',
              );
              AndroidFfiRuntimeProvider._log(
                '[TERMINAL_STATE] state=failed reason=repeated_token_loop'
                ' generated_tokens=${attemptState.estimatedTokens}'
                ' elapsed_ms=${streamingElapsed.inMilliseconds}',
              );
              _updateRuntimeStatus(
                LocalRuntimeStatus.failed,
                message: 'Repeated-token loop detected.',
                tokensGenerated: attemptState.estimatedTokens,
                elapsed: streamingElapsed,
                startedAt: state.startedAt,
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
            state.lastPiece = sanitizedPiece;
            state.repeatedTokenCount = 0;
          }
          
          _setPhase(RuntimePhase.streaming);
          _updateRuntimeStatus(
            LocalRuntimeStatus.streaming,
            message: 'Streaming',
            tokensGenerated: attemptState.estimatedTokens,
            elapsed: streamingElapsed,
            startedAt: state.startedAt,
          );
          
          AndroidFfiRuntimeProvider._log(
            '[TOKEN_EMIT] token_index=${attemptState.estimatedTokens} chars=${sanitizedPiece.length}'
            ' session=$sessionId',
          );
          AndroidFfiRuntimeProvider._log(
            '[DART_STREAM_RENDER] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} queue_size=-1 poll_iteration=${attemptState.pollIterations} subscription_alive=${!controller.isClosed}',
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
          AndroidFfiRuntimeProvider._log('[STREAM_FLUSH] event=token session=$sessionId flush_us=${flushWatch.elapsedMicroseconds}');
          
        // STATUS 2: End Of Stream (EOS) raggiunto con successo nativo
        } else if (status == 2) {
          _classifyFirstTokenTermination(
            flowState: flowState,
            attemptState: attemptState,
            reason: 'completed',
            boundary: 'poll_loop',
          );
          _setPhase(RuntimePhase.completed);
          final completedElapsed = DateTime.now().difference(state.startedAt);
          recordVerificationSuccess(modelPath: modelPath, source: 'eos');
          
          AndroidFfiRuntimeProvider._log('[FFI_EOS] session=$nativeSessionId');
          AndroidFfiRuntimeProvider._log(
            '[GENERATION_END] state=success generated_tokens=${attemptState.estimatedTokens}'
            ' elapsed_ms=${completedElapsed.inMilliseconds}',
          );
          AndroidFfiRuntimeProvider._log(
            '[FINAL_RESPONSE] eos generated_tokens=${attemptState.estimatedTokens} elapsed_ms=${completedElapsed.inMilliseconds}',
          );
          AndroidFfiRuntimeProvider._log(
            '[TERMINAL_STATE] state=success generated_tokens=${attemptState.estimatedTokens}'
            ' elapsed_ms=${completedElapsed.inMilliseconds}',
          );
          AndroidFfiRuntimeProvider._logAi('inference completed');
          AndroidFfiRuntimeProvider._log('[STREAM_ADD] event=final_chunk session=$sessionId');
          
          final flushWatch = Stopwatch()..start();
          if (!controller.isClosed) {
            final sanitizedFinalText = _flushStructuralTemplateOutput(state.fullText);
            _AndroidFfiRuntimeExecutionBoundary.emitFinalChunk(
              controller,
              text: sanitizedFinalText.isEmpty ? '\u200B' : sanitizedFinalText,
              tokensGenerated: attemptState.estimatedTokens,
              model: modelId,
            );
          }
          flushWatch.stop();
          AndroidFfiRuntimeProvider._log('[STREAM_FLUSH] event=final_chunk session=$sessionId flush_us=${flushWatch.elapsedMicroseconds}');
          
          _updateRuntimeStatus(
            LocalRuntimeStatus.completed,
            message: 'Completed',
            tokensGenerated: attemptState.estimatedTokens,
            elapsed: completedElapsed,
            startedAt: state.startedAt,
          );
          break;
          
        // STATUS -99: Annullamento confermato a livello nativo
        } else if (status == -99) {
          _classifyFirstTokenTermination(
            flowState: flowState,
            attemptState: attemptState,
            reason: 'native_cancelled',
            boundary: 'poll_loop',
            cancellation: true,
          );
          _setPhase(RuntimePhase.cancelled);
          AndroidFfiRuntimeProvider._log('[GENERATION_END] state=cancelled generated_tokens=${attemptState.estimatedTokens}');
          AndroidFfiRuntimeProvider._log(
            '[TERMINAL_STATE] state=cancelled generated_tokens=${attemptState.estimatedTokens}'
            ' elapsed_ms=${DateTime.now().difference(state.startedAt).inMilliseconds}',
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
            tokensGenerated: attemptState.estimatedTokens,
            elapsed: DateTime.now().difference(state.startedAt),
          );
          break;
          
        // STATUS -1: Errore d'esecuzione del Core Nativo C++
        } else if (status == -1) {
          _classifyFirstTokenTermination(
            flowState: flowState,
            attemptState: attemptState,
            reason: 'native_error',
            boundary: 'poll_loop',
            runtimeReset: true,
          );
          _setPhase(RuntimePhase.failed);
          clearRuntimeVerification();
          final err = AndroidFfiRuntimeProvider._safeLastError(bindings, nativeSessionId);
          AndroidFfiRuntimeProvider._log('[GENERATION_ERROR] stage=poll_token_native_error error=$err');
          final statusLower = err.toLowerCase();
          attemptState.runtimeNeedsReset = true;
          attemptState.runtimeResetReason = 'native_error';
          
          AndroidFfiRuntimeProvider._log(
            '[TERMINAL_STATE] state=native_error generated_tokens=${attemptState.estimatedTokens}'
            ' elapsed_ms=${DateTime.now().difference(state.startedAt).inMilliseconds}'
            ' error=$err',
          );
          
          if (statusLower.contains('out of memory') ||
              statusLower.contains('oom') ||
              statusLower.contains('memory')) {
            _updateRuntimeStatus(
              LocalRuntimeStatus.failed,
              message: 'Out of memory: $err',
              tokensGenerated: attemptState.estimatedTokens,
              elapsed: DateTime.now().difference(state.startedAt),
              startedAt: state.startedAt,
            );
          } else {
            _updateRuntimeStatus(
              LocalRuntimeStatus.failed,
              message: err,
              tokensGenerated: attemptState.estimatedTokens,
              elapsed: DateTime.now().difference(state.startedAt),
              startedAt: state.startedAt,
            );
          }
          
          if ((statusLower.contains('timeout') || statusLower.contains('stalled')) &&
              state.fullText.toString().trim().isNotEmpty) {
            final partialText = _flushStructuralTemplateOutput(state.fullText);
            await AndroidFfiRuntimeProvider._finishWithPartialOrRuntimeError(
              controller,
              stage: 'generation',
              message: err.isNotEmpty ? err : 'Inference failed.',
              modelId: modelId,
              fullText: partialText,
              tokensGenerated: attemptState.estimatedTokens,
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
          
        // STATUS 0: Nessun token ancora generato / C++ in computazione
        } else {
          state.consecutiveIdlePolls++;
          if (state.consecutiveIdlePolls % 120 == 0) {
            _throttledLoopLog(
              '[TOKEN_STREAM] idle polling continues: idle_polls=${state.consecutiveIdlePolls} '
              'idle_ms=${DateTime.now().difference(state.lastTokenProgressAt).inMilliseconds}',
            );
          }
          
          if (_preFirstTokenActive) {
            // Hot-path iniziale: Cessione immediata del controllo tramite Microtask Yield
            await Future<void>.delayed(Duration.zero);
          } else {
            // Campionamento Dinamico basato sul controller ottimizzato (avvio da 0ms)
            _pollingController.increaseIdleBackoff();
            if (_idleBackoffMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: _idleBackoffMs));
            } else {
              await Future<void>.delayed(Duration.zero);
            }
          }
        }
      }
    } finally {
      // Blindatura del blocco di terminazione: garantisce la liberazione atomica dei puntatori native 
      startup.freePromptNativePtr();
      _discardStructuralTemplateOutput();
      
      final context = _TerminalStateContext(
        controller: controller,
        bindings: bindings,
        sessionId: sessionId,
        modelId: modelId,
        startedAt: state.startedAt,
        estimatedTokens: attemptState.estimatedTokens,
        firstTokenAt: attemptState.firstTokenAt,
        runtimeNeedsReset: attemptState.runtimeNeedsReset,
        runtimeResetReason: attemptState.runtimeResetReason,
        tokenBufRaw: tokenBufRaw,
        attemptState: attemptState,
      );
      await _finalizeStreamingTerminalState(context);
    }
  }
}
