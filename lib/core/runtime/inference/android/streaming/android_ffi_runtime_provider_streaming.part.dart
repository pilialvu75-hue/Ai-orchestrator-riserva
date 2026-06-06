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
          await _concurrencyManager.runInferenceSerially(() async {
            AndroidFfiRuntimeProvider._log(
              '[ACTION_BODY_BEGIN] sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()} ts=${DateTime.now().microsecondsSinceEpoch}',
            );
            final sessionId = request.sessionId.trim().isEmpty
                ? 'unknown'
                : request.sessionId.trim();
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
            cancellationToken.onCancel(() => _safeCancel(startup.bindings, startup.nativeSessionId));
            await _runTokenPollingLoop(
              startup: startup,
              attemptState: firstTokenAttempt,
              flowState: flowState,
            );
            AndroidFfiRuntimeProvider._log(
              '[FFI_FLOW_EXIT] session=$sessionId first_ffi_attempted=${flowState.firstFfiInvocationAttempted}'
              ' first_ffi_completed=${flowState.firstFfiInvocationCompleted} controller_closed=${controller.isClosed}',
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
        } final {
          _finalizeFirstTokenAttempt(firstTokenAttempt);
        }
      }, (error, stack) {
        // TERMINAL SINK NON REATTIVO E MINIMALE PER L'ISOLAMENTO DELLA ZONA
        // Estraiamo i dati dell'oggetto errore riducendoli a primitive pure (Zero Object Leak Rule)
        final trace = _dehydrateAndTraceError(error, stack);
        
        // Stampa nativa per evitare l'intercettazione ricorsiva da parte del logging dell'applicazione
        print('[ZONE_FATAL_TERMINAL_SINK] Isolate Boundary Breach Intercepted.\n$trace');

        try {
          if (!controller.isClosed) {
            // Emettiamo sul confine dello stream una notifica di tipo stringa atomica immutabile
            controller.addError('Inference runtime critical boundary suspension.');
            
            // Chiusura asincrona difensiva schedulata per non bloccare il loop corrente
            scheduleMicrotask(() {
              if (!controller.isClosed) {
                controller.close();
              }
            });
          }
        } catch (sinkError) {
          print('[ZONE_CRITICAL_CONTROLLER_FAIL] Fallimento definitivo nel terminal sink: ${sinkError.toString()}');
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
}
