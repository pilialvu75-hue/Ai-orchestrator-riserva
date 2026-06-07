part of '../../runtime_core.dart';

extension AndroidFfiRuntimeStreamingVerificationExtension on AndroidFfiRuntimeProvider {
  TokenStream streamVerificationInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    try {
      AndroidFfiRuntimeProvider._log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1683 | Function: streamVerificationInference() | BEFORE entry',
      );
      final controller = StreamController<InferenceResponse>();
      
      // Utilizzo di runZonedGuarded speculare per bloccare i leak asincroni a livello di macro-task
      runZonedGuarded(() async {
        AndroidFfiRuntimeProvider._log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1688 | Function: streamVerificationInference() | BEFORE calling _runInferenceSerially()',
        );
        try {
          await _concurrencyManager.runInferenceSerially(() async {
            AndroidFfiRuntimeProvider._log(
              '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1693 | Function: streamVerificationInference() | BEFORE calling _runInVerificationScope()',
            );
            final verificationRawModelPath = request.modelPath;
            final verificationModelPath =
                verificationRawModelPath == null ||
                        verificationRawModelPath.trim().isEmpty
                    ? verificationRawModelPath
                    : await _resolveHybridModelPath(verificationRawModelPath);
            await _runInVerificationScope(
              modelPath: verificationModelPath,
              action: () async {
                // BLOCCO DI CONTENIMENTO CORE E TELEMETRIA FORENSE
                try {
                  final modelPath = verificationModelPath;
                  final modelId = request.modelId;
                  if (modelPath == null ||
                      modelPath.trim().isEmpty ||
                      modelId == null ||
                      modelId.trim().isEmpty) {
                    AndroidFfiRuntimeProvider._finishWithRuntimeError(
                      controller,
                      stage: 'verification_request_validation',
                      message: 'Missing local model path.',
                    );
                    verificationMonitor.update(
                      RuntimeVerificationPhase.failed,
                      message: 'Verification request missing model metadata.',
                    );
                    return;
                  }
                  if (!_ensureLibraryLoaded()) {
                    AndroidFfiRuntimeProvider._finishWithRuntimeError(
                      controller,
                      stage: 'verification_library_load',
                      message: 'Local AI runtime library (libllama_bridge.so) not found.',
                    );
                    verificationMonitor.update(
                      RuntimeVerificationPhase.failed,
                      message: 'libllama_bridge.so missing for current build.',
                    );
                    return;
                  }
                  final bindings = _bindings!;
                  verificationMonitor.update(
                    RuntimeVerificationPhase.loading,
                    message: 'Creating isolated verification session.',
                  );
                  final verificationSessionId = bindings.createSession(modelPath);
                  if (verificationSessionId <= 0) {
                    final err = AndroidFfiRuntimeProvider._safeLastError(bindings, verificationSessionId);
                    AndroidFfiRuntimeProvider._finishWithRuntimeError(
                      controller,
                      stage: 'verification_session_create',
                      message: 'Verification session create failed.',
                      details: err,
                    );
                    verificationMonitor.update(
                      RuntimeVerificationPhase.failed,
                      message: 'Verification session create failed: $err',
                    );
                    clearRuntimeVerification();
                    return;
                  }
                  final tokenBufRaw = calloc<Uint8>(LlamaNativeDefaults.tokenBufferSize);
                  final tokenBuf = tokenBufRaw.cast<Utf8>();
                  var emittedTokens = 0;
                  final fullText = StringBuffer();
                  
                  final verificationPromptPtr =
                      request.prompt.toNativeUtf8(allocator: calloc);
                  Pointer<Utf8>? verificationPromptPtrOrNull = verificationPromptPtr;
                  void freeVerificationPromptPtr() {
                    final ptr = verificationPromptPtrOrNull;
                    if (ptr != null) {
                      calloc.free(ptr);
                      verificationPromptPtrOrNull = null;
                    }
                  }
                  try {
                    final startResult = bindings.startGeneration(
                      verificationSessionId,
                      verificationPromptPtr,
                      request.maxTokens.clamp(1, AndroidFfiRuntimeProvider._safeMaxTokens),
                      request.temperature,
                    );
                    if (startResult != 0) {
                      freeVerificationPromptPtr();
                      final err = AndroidFfiRuntimeProvider._safeLastError(bindings, verificationSessionId);
                      AndroidFfiRuntimeProvider._finishWithRuntimeError(
                        controller,
                        stage: 'verification_start_generation',
                        message: 'Failed to start isolated runtime verification.',
                        details: err,
                      );
                      verificationMonitor.update(
                        RuntimeVerificationPhase.failed,
                        message: 'Verification start_generation failed: $err',
                      );
                      clearRuntimeVerification();
                      return;
                    }
                    verificationMonitor.update(
                      RuntimeVerificationPhase.running,
                      message: 'Verification inference running.',
                    );
                    final startedAt = DateTime.now();
                    var verificationFirstTokenReceived = false;
                    while (true) {
                      if (cancellationToken.isCancelled || controller.isClosed) {
                        freeVerificationPromptPtr();
                        _safeCancel(bindings, verificationSessionId);
                        if (!controller.isClosed) {
                          AndroidFfiRuntimeProvider._finishWithRuntimeError(
                            controller,
                            stage: 'verification_cancelled',
                            message: 'Verification cancelled.',
                            state: InferenceTerminalState.cancelled,
                          );
                        }
                        verificationMonitor.update(
                          RuntimeVerificationPhase.failed,
                          message: 'Verification cancelled.',
                        );
                        return;
                      }
                      final elapsed = DateTime.now().difference(startedAt);
                      if (elapsed > AndroidFfiRuntimeProvider._generationTimeout) {
                        freeVerificationPromptPtr();
                        _setPhase(RuntimePhase.stalled);
                        _safeCancel(bindings, verificationSessionId);
                        AndroidFfiRuntimeProvider._finishWithRuntimeError(
                          controller,
                          stage: 'verification_timeout',
                          message: 'Runtime verification timed out.',
                          state: InferenceTerminalState.timeout,
                        );
                        verificationMonitor.update(
                          RuntimeVerificationPhase.failed,
                          message: 'Runtime verification timed out.',
                        );
                        clearRuntimeVerification();
                        return;
                      }
                      AndroidFfiRuntimeProvider._log(
                        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1813 | Function: streamVerificationInference() | BEFORE verification pollToken loop iteration',
                      );
                      final status = bindings.pollToken(verificationSessionId, tokenBuf);
                      AndroidFfiRuntimeProvider._log(
                        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1817 | Function: streamVerificationInference() | AFTER verification pollToken loop iteration status=$status',
                      );
                      if (status == 1) {
                        final piece = tokenBuf.toDartString();
                        final trimmedPiece = piece.trim();
                        if (_shouldIgnoreToken(trimmedPiece)) {
                          continue;
                        }
                        final sanitizedPiece = _sanitizeStructuralTemplateOutput(piece);
                        if (sanitizedPiece.trim().isEmpty) {
                          continue;
                        }
                        if (_isDeveloperMode) {
                          AndroidFfiRuntimeProvider._log('RAW_TOKEN: "${piece.replaceAll('\n', r'\n')}"');
                          AndroidFfiRuntimeProvider._log('SANITIZED_TOKEN: "${sanitizedPiece.replaceAll('\n', r'\n')}"');
                        }

                        if (!verificationFirstTokenReceived) {
                          freeVerificationPromptPtr();
                          verificationFirstTokenReceived = true;
                          _setPhase(RuntimePhase.streaming);
                        }
                        emittedTokens++;
                        fullText.write(sanitizedPiece);
                        _AndroidFfiRuntimeExecutionBoundary.emitTokenChunk(
                          controller,
                          text: sanitizedPiece,
                          model: modelId,
                        );
                        continue;
                      }
                      if (status == 2) {
                        freeVerificationPromptPtr();
                        _setPhase(RuntimePhase.completed);
                        break;
                      }
                      if (status == -1) {
                        freeVerificationPromptPtr();
                        _setPhase(RuntimePhase.failed);
                        final err = AndroidFfiRuntimeProvider._safeLastError(bindings, verificationSessionId);
                        AndroidFfiRuntimeProvider._finishWithRuntimeError(
                          controller,
                          stage: 'verification_poll_token',
                          message: 'Verification poll_token failed.',
                          details: err,
                        );
                        verificationMonitor.update(
                          RuntimeVerificationPhase.failed,
                          message: 'Verification poll_token failed: $err',
                        );
                        clearRuntimeVerification();
                        return;
                      }
                      if (status == -99) {
                        freeVerificationPromptPtr();
                        _setPhase(RuntimePhase.cancelled);
                        AndroidFfiRuntimeProvider._finishWithRuntimeError(
                          controller,
                          stage: 'verification_cancelled_native',
                          message: 'Verification cancelled by native runtime.',
                          state: InferenceTerminalState.cancelled,
                        );
                        verificationMonitor.update(
                          RuntimeVerificationPhase.failed,
                          message: 'Verification cancelled by native runtime.',
                        );
                        return;
                      }
                      await Future<void>.delayed(const Duration(milliseconds: 24));
                    }

                    recordVerificationSuccess(
                      modelPath: modelPath,
                      source: 'verification_scope',
                    );
                    verificationMonitor.update(
                      RuntimeVerificationPhase.passed,
                      message: 'Runtime verification passed.',
                    );
                    if (!controller.isClosed) {
                      final finalText = _flushStructuralTemplateOutput(fullText);
                      _AndroidFfiRuntimeExecutionBoundary.emitFinalChunk(
                        controller,
                        text: finalText.isEmpty ? '\u200B' : finalText,
                        tokensGenerated: emittedTokens,
                        model: modelId,
                      );
                      await controller.close();
                    }
                  } finally {
                    freeVerificationPromptPtr();
                    _discardStructuralTemplateOutput();
                    calloc.free(tokenBufRaw);
                    await _shutdownNativeSessionGracefully(
                      bindings,
                      verificationSessionId,
                      reason: 'verification_scope_cleanup',
                      modelPath: modelPath,
                    );
                  }
                } catch (e, st) {
                  // TERMINAL SINK INTERNO DI VERIFICA: Cattura, deidratazione e rimozione del leak degli oggetti
                  final verificationTrace = _dehydrateAndTraceError(e, st);
                  print('[VERIFICATION_SCOPE_FAULT_TERMINAL_SINK] Eccezione intercettata nel modulo di verifica.\n$verificationTrace');
                  
                  try {
                    if (!controller.isClosed) {
                      controller.addError('Verification runtime critical boundary suspension.');
                      scheduleMicrotask(() {
                        if (!controller.isClosed) {
                          controller.close();
                        }
                      });
                    }
                  } catch (sinkError) {
                    print('[VERIFICATION_SINK_FAIL] Fallimento definitivo nel controller di verifica: $sinkError');
                  }
                  
                  verificationMonitor.update(
                    RuntimeVerificationPhase.failed,
                    message: 'Verification scope exception sanitized.',
                  );
                }
              },
            );
            AndroidFfiRuntimeProvider._log(
              '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1922 | Function: streamVerificationInference() | AFTER calling _runInVerificationScope()',
            );
          });
          AndroidFfiRuntimeProvider._log(
            '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1926 | Function: streamVerificationInference() | AFTER calling _runInferenceSerially()',
          );
        } catch (e, st) {
          final trace = _dehydrateAndTraceError(e, st);
          print('[VERIFICATION_QUEUE_FAULT_TERMINAL_SINK] Eccezione intercettata a livello di coda di verifica.\n$trace');
        }
      }, (error, stack) {
        // TERMINAL SINK ESTERNO DI VERIFICA (ZONE BOUNDARY)
        final trace = _dehydrateAndTraceError(error, stack);
        print('[VERIFICATION_ZONE_FATAL_TERMINAL_SINK] Eccezione asincrona non gestita catturata nella zona di verifica.\n$trace');
        
        try {
          if (!controller.isClosed) {
            controller.addError('Verification zone execution critical failure.');
            scheduleMicrotask(() {
              if (!controller.isClosed) {
                controller.close();
              }
            });
          }
        } catch (sinkError) {
          print('[VERIFICATION_ZONE_SINK_FAIL] Fallimento nel sink della zona di verifica: $sinkError');
        }
      });

      AndroidFfiRuntimeProvider._log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1936 | Function: streamVerificationInference() | AFTER exit',
      );
      return controller.stream;
    } catch (_) {
      rethrow;
    }
  }
}
