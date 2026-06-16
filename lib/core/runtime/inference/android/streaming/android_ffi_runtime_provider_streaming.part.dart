part of '../../runtime_core.dart';

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
      AndroidFfiRuntimeProvider._log(
        '[FORENSIC_STREAM_INFERENCE_ACTIVE] streamInferenceEntered=true sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}',
      );
      final controller = StreamController<InferenceResponse>();
      AndroidFfiRuntimeProvider._log(
        '[STREAM_CONTROLLER_CREATED] sessionId=${request.sessionId} modelId=${request.modelId}',
      );
      final flowState = _StreamFlowControlState();
      final sessionId = request.sessionId.trim().isEmpty ? 'unknown' : request.sessionId.trim();
      final firstTokenAttempt = _beginFirstTokenAttempt(
        sessionId: sessionId,
        modelId: request.modelId ?? '',
        isForensicSelfTest:
            request.sessionId.trim() == AndroidFfiRuntimeProvider._forensicSelfTestSessionId,
        dartThreadId: AndroidFfiRuntimeProvider._currentThreadId(),
      );
      controller.onCancel = () {
        if (!flowState.firstFfiInvocationAttempted) {
          AndroidFfiRuntimeProvider._log(
            '[FFI_BRANCH_RETURN] session=${request.sessionId} branch=stream_listener_cancel'
            ' reason=stream listener detached before first FFI call',
          );
        }
        AndroidFfiRuntimeProvider._log(
          '[FFI_BRANCH] session=${request.sessionId} name=stream_listener_cancel'
          ' first_ffi_attempted=${flowState.firstFfiInvocationAttempted}',
        );
      };
      AndroidFfiRuntimeProvider._log('[CANCELLATION_HANDLER_REGISTERED] sessionId=${request.sessionId}');
      AndroidFfiRuntimeProvider._log(
        '[ASYNC_CLOSURE_LAUNCH_BEGIN] sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()} inferenceTailHash=${(_inferenceTail ?? Future<void>.value()).hashCode}',
      );

      runZonedGuarded(() async {
        AndroidFfiRuntimeProvider._log(
          '[ASYNC_CLOSURE_ENTER] sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}',
        );
        AndroidFfiRuntimeProvider._log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 508 | Function: streamInference() | BEFORE calling _runInferenceSerially()',
        );
        try {
          var slotClaimed = false;
          var pollingLoopEntered = false;
          final sessionId = request.sessionId.trim().isEmpty
              ? 'unknown'
              : request.sessionId.trim();
          try {
            await _concurrencyManager.runInferenceSerially(() async {
              AndroidFfiRuntimeProvider._log(
                '[ACTION_BODY_BEGIN] sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()} ts=${DateTime.now().microsecondsSinceEpoch}',
              );
              final isForensicSelfTest =
                  request.sessionId.trim() == AndroidFfiRuntimeProvider._forensicSelfTestSessionId;
              if (!isForensicSelfTest && !_claimInferenceSlot(sessionId)) {
                _classifyFirstTokenTermination(
                  flowState: flowState,
                  attemptState: firstTokenAttempt,
                  reason: 'recursive_inference_guard',
                  boundary: 'recursive_inference_guard',
                );
                AndroidFfiRuntimeProvider._log('[FFI_BRANCH] session=$sessionId name=recursive_inference_guard');
                AndroidFfiRuntimeProvider._log('[SESSION] recursive_guard_triggered session=$sessionId');
                await _fatalEarlyExit(
                  flowState: flowState,
                  controller: controller,
                  sessionId: sessionId,
                  branch: 'recursive_inference_guard',
                  reason: 'Recursive inference call blocked for session $sessionId.',
                  stage: 'recursive_inference_guard',
                );
                AndroidFfiRuntimeProvider._log(
                  '[FFI_FLOW_EXIT] session=$sessionId first_ffi_attempted=${flowState.firstFfiInvocationAttempted}'
                  ' first_ffi_completed=${flowState.firstFfiInvocationCompleted} controller_closed=${controller.isClosed}',
                );
                return;
              }
              if (!isForensicSelfTest) {
                slotClaimed = true;
              }
              if (isForensicSelfTest) {
                AndroidFfiRuntimeProvider._log(
                  '[VERIFICATION_UI_IGNORED] verification_scope=true reason=skip_activeInferenceSessions_tracking session=$sessionId',
                );
              }
              final startup = await _prepareGenerationStartup(
                controller: controller,
                request: request,
                cancellationToken: cancellationToken,
                flowState: flowState,
                sessionId: sessionId,
                modelId: request.modelId,
                modelPath: request.modelPath,
                isForensicSelfTest: isForensicSelfTest,
                dartThreadId: AndroidFfiRuntimeProvider._currentThreadId(),
              );
              if (startup == null) {
                AndroidFfiRuntimeProvider._log(
                  '[FFI_FLOW_EXIT] session=$sessionId first_ffi_attempted=${flowState.firstFfiInvocationAttempted}'
                  ' first_ffi_completed=${flowState.firstFfiInvocationCompleted} controller_closed=${controller.isClosed}',
                );
                return;
              }

              // ── FIX: Estrazione metadati META dal prompt ──
              final sampling = _SamplingParams.fromPrompt(startup.prompt);
              final cleanPrompt = startup.prompt.replaceAll(RegExp(r'<!--META.*?-->\n?'), '');
              AndroidFfiRuntimeProvider._log(
                '[SAMPLING_PARAMS_EXTRACTED] session=$sessionId temp=${sampling.temperature} top_p=${sampling.topP} repeat_penalty=${sampling.repeatPenalty}',
              );
              // ─────────────────────────────────────────────

              pollingLoopEntered = true;
              cancellationToken.onCancel(() => _safeCancel(startup.bindings, startup.nativeSessionId));
              
              // Passa cleanPrompt e sampling al loop di polling
              await _runTokenPollingLoopWithSampling(
                startup: startup,
                attemptState: firstTokenAttempt,
                flowState: flowState,
                cleanPrompt: cleanPrompt,
                sampling: sampling,
              );
              
              AndroidFfiRuntimeProvider._log(
                '[FFI_FLOW_EXIT] session=$sessionId first_ffi_attempted=${flowState.firstFfiInvocationAttempted}'
                ' first_ffi_completed=${flowState.firstFfiInvocationCompleted} controller_closed=${controller.isClosed}',
              );
            });
          } finally {
            if (slotClaimed && !pollingLoopEntered) {
              _releaseInferenceSlot(sessionId);
              _flushPendingRuntimeVerificationClear();
            }
          }
          AndroidFfiRuntimeProvider._log(
            '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1655 | Function: streamInference() | AFTER calling _runInferenceSerially()',
          );
        } catch (e, stackTrace) {
          AndroidFfiRuntimeProvider._log(
            '[AI_RUNTIME_MONITOR] FORENSIC_EXCEPTION - File: android_ffi_runtime_provider.dart | Line: 1659 | Function: streamInference() | BEFORE rethrow after async execution exception: $e \n $stackTrace',
          );
          rethrow;
        } finally {
          _finalizeFirstTokenAttempt(firstTokenAttempt);
        }
      }, (error, stack) {
        final trace = _dehydrateAndTraceError(error, stack);
        stderr.writeln('[ZONE_FATAL_TERMINAL_SINK] Isolate Boundary Breach Intercepted.\n$trace');
        try {
          if (!controller.isClosed) {
            controller.addError('Inference runtime critical boundary suspension.');
            scheduleMicrotask(() {
              if (!controller.isClosed) {
                controller.close();
              }
            });
          }
        } catch (sinkError) {
          stderr.writeln('[ZONE_CRITICAL_CONTROLLER_FAIL] Fallimento definitivo nel terminal sink: ${sinkError.toString()}');
        }
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

  // ── Nuovo metodo con sampling dinamico ──────────────────────────────────
  Future<void> _runTokenPollingLoopWithSampling({
    required _GenerationStartup startup,
    required _FirstTokenAttemptState attemptState,
    required _StreamFlowControlState flowState,
    required String cleanPrompt,
    required _SamplingParams sampling,
  }) async {
    final bindings = startup.bindings;
    final nativeSessionId = startup.nativeSessionId;
    final modelId = startup.modelId;
    final modelPath = startup.modelPath;
    final sessionId = startup.sessionId;

    try {
      _setPhase(RuntimePhase.startingGeneration);
      
      // Usa cleanPrompt senza <!--META--> e passa temperature dinamica
      final promptPtr = cleanPrompt.toNativeUtf8().cast<Utf8>();
      final startOk = await _runNativeCallWithTimeout(
        stage: 'start_generation',
        timeout: _startGenerationTimeout,
        call: () => bindings.sessionStartGen(
          nativeSessionId,
          promptPtr,
          startup.maxTokens,
          sampling.temperature, // FIX: temp dinamica da META
          sampling.topP,        // FIX: top_p dinamico
          sampling.repeatPenalty, // FIX: repeat_penalty dinamico
          0, // min_p
          40, // top_k
          512, // mirostat_tau
          1.7, // mirostat_eta
          0, // mirostat
          0, // grammar_token
          Pointer<Void>.fromAddress(0),
        ),
      );
      malloc.free(promptPtr);

      if (startOk != 0) {
        final err = _safeLastError(bindings, nativeSessionId);
        await _fatalEarlyExit(
          flowState: flowState,
          controller: startup.controller,
          sessionId: sessionId,
          branch: 'start_generation_failed',
          reason: 'Native start_gen failed: $err',
          stage: 'start_generation',
        );
        return;
      }

      _setPhase(RuntimePhase.waitingFirstToken);
      await _runTokenPollingLoop(
        startup: startup,
        attemptState: attemptState,
        flowState: flowState,
      );
    } catch (e, st) {
      AndroidFfiRuntimeProvider._log('[TOKEN_LOOP_EXCEPTION] $e\n$st');
      await _fatalEarlyExit(
        flowState: flowState,
        controller: startup.controller,
        sessionId: sessionId,
        branch: 'token_loop_exception',
        reason: e.toString(),
        stage: 'token_polling',
      );
    }
  }
}
