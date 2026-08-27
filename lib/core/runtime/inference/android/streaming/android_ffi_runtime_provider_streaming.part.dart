part of '../../runtime_core.dart';

/// Set di modelId ufficialmente validati per il runtime Android FFI.
///
/// I modelli importati dall'utente (es. "Llama-3.2-1B-Instruct-Q4_K_M")
/// vengono riconosciuti per pattern tramite [_isImportedModelSafeForAndroid].
/// Non si aggiungono qui le costanti perché i nomi importati sono arbitrari.
const Set<String> _androidSafeModelIds = {
  LocalInferenceModelIds.llama1b,
  LocalInferenceModelIds.gemma2b,
  LocalInferenceModelIds.gemma2_2bIt,
  LocalInferenceModelIds.deepSeekR1_1_5b,
  LocalInferenceModelIds.qwen3_1_7b,
  LocalInferenceModelIds.phi3_5_mini,
};

/// Verifica se un modelId importato dall'utente è compatibile con
/// il runtime Android FFI tramite pattern matching sul nome.
///
/// Architetture supportate da llama.cpp su Android arm64:
/// - Llama (1B, 3B) — architettura transformer standard
/// - Mistral / Mixtral — compatibile con llama.cpp
/// - Qwen / Qwen2 / Qwen3 — supportato
/// - DeepSeek distill (Qwen-based) — supportato
/// - Gemma / Gemma2 — supportato
/// - Phi-3 / Phi-3.5 — supportato
///
/// Architetture NON supportate: Falcon, MPT, RWKV, Mamba.
bool _isImportedModelSafeForAndroid(String modelId) {
  final id = modelId.trim().toLowerCase();
  return id.contains('llama') ||
      id.contains('mistral') ||
      id.contains('mixtral') ||
      id.contains('qwen') ||
      id.contains('deepseek') ||
      id.contains('gemma') ||
      id.contains('phi-3') ||
      id.contains('phi3') ||
      id.contains('smollm') ||
      id.contains('tinyllama');
}

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
      _pollingController.resetIdleBackoff();

      final controller = StreamController<InferenceResponse>();
      AndroidFfiRuntimeProvider._log(
        '[STREAM_CONTROLLER_CREATED] sessionId=${request.sessionId} modelId=${request.modelId}',
      );

      final flowState = _StreamFlowControlState();
      final sessionId =
          request.sessionId.trim().isEmpty
              ? 'unknown'
              : request.sessionId.trim();

      final firstTokenAttempt = _beginFirstTokenAttempt(
        sessionId: sessionId,
        modelId: request.modelId ?? '',
        isForensicSelfTest:
            request.sessionId.trim() ==
            AndroidFfiRuntimeProvider._forensicSelfTestSessionId,
        dartThreadId: AndroidFfiRuntimeProvider._currentThreadId(),
      );

      /*
       * STREAM LIFECYCLE / CANCELLATION CONTRACT
       *
       * La cancellazione della subscription deve arrivare fino al runtime.
       *
       * Prima di questa propagazione, onCancel registrava solamente un log:
       *
       *   stream subscription cancellata
       *          ↓
       *   CancellationToken ancora attivo
       *          ↓
       *   native generation potenzialmente ancora attiva
       *
       * Questo lasciava una finestra di race tra la chiusura/cancellazione
       * dello stream Dart e la generazione nativa.
       *
       * CancellationToken.cancel() è idempotente, quindi è sicuro chiamarlo
       * anche se un altro percorso ha già richiesto la cancellazione.
       */
      controller.onCancel = () {
        AndroidFfiRuntimeProvider._log(
          '[STREAM_CANCEL_REQUESTED] '
          'session=$sessionId '
          'modelId=${request.modelId} '
          'token_was_cancelled=${cancellationToken.isCancelled}',
        );

        if (!flowState.firstFfiInvocationAttempted) {
          AndroidFfiRuntimeProvider._log(
            '[FFI_BRANCH_RETURN] session=${request.sessionId} '
            'branch=stream_listener_cancel '
            'reason=stream listener detached before first FFI call',
          );
        }

        AndroidFfiRuntimeProvider._log(
          '[FFI_BRANCH] session=${request.sessionId} '
          'name=stream_listener_cancel '
          'first_ffi_attempted=${flowState.firstFfiInvocationAttempted}',
        );

        /*
         * Propaga immediatamente la cancellazione verso il runtime.
         *
         * Se lo startup non ha ancora registrato il proprio listener,
         * CancellationToken conserva lo stato cancelled; quando
         * _prepareGenerationStartup registrerà onCancel(), il listener
         * verrà invocato immediatamente.
         */
        cancellationToken.cancel();

        AndroidFfiRuntimeProvider._log(
          '[STREAM_CANCEL_PROPAGATED] '
          'session=$sessionId '
          'token_is_cancelled=${cancellationToken.isCancelled}',
        );
      };

      AndroidFfiRuntimeProvider._log(
        '[CANCELLATION_HANDLER_REGISTERED] sessionId=${request.sessionId}',
      );
      AndroidFfiRuntimeProvider._log(
        '[ASYNC_CLOSURE_LAUNCH_BEGIN] sessionId=${request.sessionId} '
        'modelId=${request.modelId} '
        'isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()} '
        'inferenceTailHash=${(_inferenceTail ?? Future<void>.value()).hashCode}',
      );

      runZonedGuarded(() async {
        AndroidFfiRuntimeProvider._log(
          '[ASYNC_CLOSURE_ENTER] sessionId=${request.sessionId} '
          'modelId=${request.modelId} '
          'isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()}',
        );
        AndroidFfiRuntimeProvider._log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 508 | Function: streamInference() | BEFORE calling _runInferenceSerially()',
        );

        try {
          var slotClaimed = false;
          var pollingLoopEntered = false;

          final sessionId =
              request.sessionId.trim().isEmpty
                  ? 'unknown'
                  : request.sessionId.trim();

          try {
            await _concurrencyManager.runInferenceSerially(() async {
              AndroidFfiRuntimeProvider._log(
                '[ACTION_BODY_BEGIN] sessionId=${request.sessionId} '
                'modelId=${request.modelId} '
                'isolateHash=${AndroidFfiRuntimeProvider._currentThreadId()} '
                'ts=${DateTime.now().microsecondsSinceEpoch}',
              );

              /*
               * Se il consumer ha già cancellato lo stream mentre
               * l'operazione era in coda presso il serializzatore,
               * non dobbiamo iniziare una nuova generazione.
               *
               * Questo controllo è importante perché la cancellazione
               * può avvenire prima dell'ingresso effettivo nell'action body.
               */
              if (cancellationToken.isCancelled) {
                AndroidFfiRuntimeProvider._log(
                  '[FFI_BRANCH] '
                  'session=$sessionId '
                  'name=cancelled_before_action_body',
                );
                AndroidFfiRuntimeProvider._log(
                  '[STREAM_CANCEL_ABORT] '
                  'session=$sessionId '
                  'reason=cancellation_received_before_action_body',
                );
                return;
              }

              final isForensicSelfTest =
                  request.sessionId.trim() ==
                  AndroidFfiRuntimeProvider._forensicSelfTestSessionId;

              if (!isForensicSelfTest &&
                  !_claimInferenceSlot(sessionId)) {
                _classifyFirstTokenTermination(
                  flowState: flowState,
                  attemptState: firstTokenAttempt,
                  reason: 'recursive_inference_guard',
                  boundary: 'recursive_inference_guard',
                );
                AndroidFfiRuntimeProvider._log(
                  '[FFI_BRANCH] '
                  'session=$sessionId '
                  'name=recursive_inference_guard',
                );
                AndroidFfiRuntimeProvider._log(
                  '[SESSION] recursive_guard_triggered session=$sessionId',
                );

                await _fatalEarlyExit(
                  flowState: flowState,
                  controller: controller,
                  sessionId: sessionId,
                  branch: 'recursive_inference_guard',
                  reason:
                      'Recursive inference call blocked for session $sessionId.',
                  stage: 'recursive_inference_guard',
                );

                AndroidFfiRuntimeProvider._log(
                  '[FFI_FLOW_EXIT] '
                  'session=$sessionId '
                  'first_ffi_attempted=${flowState.firstFfiInvocationAttempted} '
                  'first_ffi_completed=${flowState.firstFfiInvocationCompleted} '
                  'controller_closed=${controller.isClosed}',
                );
                return;
              }

              if (!isForensicSelfTest) {
                slotClaimed = true;
              }

              if (isForensicSelfTest) {
                AndroidFfiRuntimeProvider._log(
                  '[VERIFICATION_UI_IGNORED] '
                  'verification_scope=true '
                  'reason=skip_activeInferenceSessions_tracking '
                  'session=$sessionId',
                );
              }

              /*
               * La cancellazione può arrivare anche mentre il task è stato
               * serializzato ma prima che _prepareGenerationStartup()
               * termini. Non possiamo interrompere arbitrariamente un
               * await già in corso, ma possiamo evitare di proseguire
               * nella fase di polling una volta che lo startup ritorna.
               */
              final startup = await _prepareGenerationStartup(
                controller: controller,
                request: request,
                cancellationToken: cancellationToken,
                flowState: flowState,
                sessionId: sessionId,
                modelId: request.modelId,
                modelPath: request.modelPath,
                isForensicSelfTest: isForensicSelfTest,
                dartThreadId:
                    AndroidFfiRuntimeProvider._currentThreadId(),
              );

              if (startup == null) {
                AndroidFfiRuntimeProvider._log(
                  '[FFI_FLOW_EXIT] '
                  'session=$sessionId '
                  'first_ffi_attempted=${flowState.firstFfiInvocationAttempted} '
                  'first_ffi_completed=${flowState.firstFfiInvocationCompleted} '
                  'controller_closed=${controller.isClosed}',
                );
                return;
              }

              /*
               * Il token potrebbe essere stato cancellato durante:
               *
               *   model validation
               *   warmup
               *   library load
               *   native session creation
               *   prompt construction
               *
               * _prepareGenerationStartup() registra già il proprio
               * listener onCancel. Poiché CancellationToken è idempotente,
               * il listener viene eseguito immediatamente se la cancellazione
               * era già avvenuta.
               *
               * Qui evitiamo comunque di entrare nel polling se il token
               * risulta già cancellato.
               */
              if (cancellationToken.isCancelled) {
                AndroidFfiRuntimeProvider._log(
                  '[FFI_BRANCH] '
                  'session=$sessionId '
                  'name=cancelled_after_startup',
                );

                AndroidFfiRuntimeProvider._log(
                  '[STREAM_CANCEL_ABORT] '
                  'session=$sessionId '
                  'reason=cancellation_received_during_generation_startup',
                );

                _safeCancel(
                  startup.bindings,
                  startup.nativeSessionId,
                );

                AndroidFfiRuntimeProvider._log(
                  '[FFI_FLOW_EXIT] '
                  'session=$sessionId '
                  'reason=cancelled_after_startup '
                  'native_session=${startup.nativeSessionId} '
                  'controller_closed=${controller.isClosed}',
                );
                return;
              }

              pollingLoopEntered = true;

              /*
               * Questo listener rimane il ponte definitivo tra il
               * CancellationToken e la sessione nativa.
               *
               * Se onCancel è già stato chiamato prima dello startup,
               * CancellationToken esegue immediatamente il callback.
               */
              cancellationToken.onCancel(() {
                AndroidFfiRuntimeProvider._log(
                  '[NATIVE_CANCEL_PROPAGATION] '
                  'session=$sessionId '
                  'nativeSession=${startup.nativeSessionId}',
                );

                _safeCancel(
                  startup.bindings,
                  startup.nativeSessionId,
                );
              });

              await _runTokenPollingLoop(
                startup: startup,
                attemptState: firstTokenAttempt,
                flowState: flowState,
              );

              AndroidFfiRuntimeProvider._log(
                '[FFI_FLOW_EXIT] '
                'session=$sessionId '
                'first_ffi_attempted=${flowState.firstFfiInvocationAttempted} '
                'first_ffi_completed=${flowState.firstFfiInvocationCompleted} '
                'controller_closed=${controller.isClosed}',
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
            '[AI_RUNTIME_MONITOR] FORENSIC_EXCEPTION - '
            'File: android_ffi_runtime_provider.dart | '
            'Line: 1659 | Function: streamInference() | '
            'BEFORE rethrow after async execution exception: '
            '$e \n $stackTrace',
          );
          rethrow;
        } finally {
          _finalizeFirstTokenAttempt(firstTokenAttempt);
        }
      }, (error, stack) {
        final trace = _dehydrateAndTraceError(error, stack);

        stderr.writeln(
          '[ZONE_FATAL_TERMINAL_SINK] '
          'Isolate Boundary Breach Intercepted.\n$trace',
        );

        try {
          if (!controller.isClosed) {
            controller.addError(
              'Inference runtime critical boundary suspension.',
            );

            scheduleMicrotask(() {
              if (!controller.isClosed) {
                controller.close();
              }
            });
          }
        } catch (sinkError) {
          stderr.writeln(
            '[ZONE_CRITICAL_CONTROLLER_FAIL] '
            'Fallimento definitivo nel terminal sink: '
            '${sinkError.toString()}',
          );
        }
      });

      AndroidFfiRuntimeProvider._log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1666 | Function: streamInference() | AFTER exit',
      );

      return controller.stream;
    } catch (e, stackTrace) {
      AndroidFfiRuntimeProvider._log(
        '[FORENSIC_UNHANDLED_EXCEPTION] '
        'error=$e stackTrace=$stackTrace',
      );
      rethrow;
    }
  }
}
