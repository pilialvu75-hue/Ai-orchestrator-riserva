import 'dart:ffi';

import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ffi/ffi.dart';

class LlamaBridgeBindings {
  LlamaBridgeBindings(DynamicLibrary lib)
      : _loadModel = lib.lookupFunction<LlbLoadModelNative, LlbLoadModelDart>(
          'llb_load_model',
        ),
        _startGen = lib.lookupFunction<LlbStartGenNative, LlbStartGenDart>(
          'llb_start_gen',
        ),
        _pollToken = lib.lookupFunction<LlbPollTokenNative, LlbPollTokenDart>(
          'llb_poll_token',
        ),
        _cancel = lib.lookupFunction<LlbCancelNative, LlbCancelDart>(
          'llb_cancel',
        ),
        _freeModel = lib.lookupFunction<LlbFreeModelNative, LlbFreeModelDart>(
          'llb_free_model',
        ),
        _lastError =
            lib.lookupFunction<LlbLastErrorNative, LlbLastErrorDart>(
          'llb_last_error',
        ),
        _isLoaded = lib.lookupFunction<LlbIsLoadedNative, LlbIsLoadedDart>(
          'llb_is_loaded',
        );

  final LlbLoadModelDart _loadModel;
  final LlbStartGenDart _startGen;
  final LlbPollTokenDart _pollToken;
  final LlbCancelDart _cancel;
  final LlbFreeModelDart _freeModel;
  final LlbLastErrorDart _lastError;
  final LlbIsLoadedDart _isLoaded;

  int loadModel(String modelPath) {
    final pathPtr = modelPath.toNativeUtf8();
    try {
      return _loadModel(pathPtr, LlamaNativeDefaults.nCtx, LlamaNativeDefaults.nThreads);
    } finally {
      calloc.free(pathPtr);
    }
  }

  int startGeneration(String prompt, int maxTokens, double temperature) {
    final promptPtr = prompt.toNativeUtf8();
    try {
      return _startGen(promptPtr, maxTokens, temperature);
    } finally {
      calloc.free(promptPtr);
    }
  }

  int pollToken(Pointer<Utf8> buf) => _pollToken(buf, LlamaNativeDefaults.tokenBufferSize);

  void cancel() => _cancel();

  void freeModel() => _freeModel();

  String lastError() => _lastError().toDartString();

  int isLoaded() => _isLoaded();
}
