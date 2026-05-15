import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_bindings.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_ffi_loader.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ai_orchestrator/core/runtime/native/native_runtime_bridge.dart';
import 'package:ai_orchestrator/core/runtime/native/native_runtime_errors.dart';

/// Android-specific implementation of [NativeRuntimeBridge].
///
/// Wraps [LlamaFfiLoader] and [LlamaBridgeBindings] to isolate all FFI
/// state in one place.  **This class must only be instantiated on Android.**
/// Callers should guard with [Platform.isAndroid] before constructing it.
///
/// All public methods throw [NativeRuntimeException] subclasses on failure
/// so that the boot pipeline can react with precise error-handling.
class AndroidNativeRuntimeBridge implements NativeRuntimeBridge {
  AndroidNativeRuntimeBridge();

  LlamaFfiLibraryHandle? _libraryHandle;
  LlamaBridgeBindings? _bindings;

  @override
  bool get isLoaded => _bindings != null;

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Loads `libllama_bridge.so` and binds all required symbols.
  ///
  /// Returns `true` on success.
  /// Throws [NativeLibraryNotFoundException] when the library cannot be opened.
  /// Throws [NativeSymbolBindingException] when symbol lookup fails.
  @override
  Future<bool> initialize() async {
    debugPrint('[NATIVE_READY] Initializing Android native runtime bridge');

    if (!Platform.isAndroid) {
      const msg =
          'AndroidNativeRuntimeBridge must only be used on Android';
      debugPrint('[NATIVE_READY] FAIL – $msg');
      throw NativeLibraryNotFoundException(message: msg);
    }

    final handle = LlamaFfiLoader.tryLoadBridgeLibrary(log: debugPrint);

    if (handle == null) {
      final msg =
          'Failed to load ${LlamaFfiLoader.bridgeLibraryName} '
          '(ABI: ${LlamaFfiLoader.currentAbiName})';
      debugPrint('[NATIVE_READY] FAIL – $msg');
      throw NativeLibraryNotFoundException(message: msg);
    }

    _libraryHandle = handle;
    _bindings = handle.bindings;

    debugPrint(
      '[NATIVE_READY] Library loaded: ${LlamaFfiLoader.bridgeLibraryName} '
      'ABI=${LlamaFfiLoader.currentAbiName}',
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // Model
  // ---------------------------------------------------------------------------

  /// Loads the GGUF model at [modelPath] into the native context.
  ///
  /// [nCtx] and [nThreads] default to the safe mobile values defined in
  /// [LlamaNativeDefaults].
  ///
  /// Throws [NativeModelLoadException] when the native bridge returns a
  /// non-zero error code.
  @override
  Future<bool> loadModel(
    String modelPath, {
    int nCtx = LlamaNativeDefaults.nCtx,
    int nThreads = LlamaNativeDefaults.nThreads,
  }) async {
    _assertInitialized('loadModel');

    debugPrint(
      '[MODEL_VALIDATION] Loading model: $modelPath '
      'nCtx=$nCtx nThreads=$nThreads',
    );

    final result = _bindings!.loadModel(modelPath);

    if (result != 0) {
      final error = _bindings!.lastError();
      final msg = 'loadModel failed (code=$result): $error';
      debugPrint('[MODEL_VALIDATION] FAIL – $msg');
      throw NativeModelLoadException(message: msg, code: result);
    }

    debugPrint('[MODEL_VALIDATION] OK – model loaded: $modelPath');
    return true;
  }

  // ---------------------------------------------------------------------------
  // Generation
  // ---------------------------------------------------------------------------

  /// Begins streaming generation for [prompt].
  ///
  /// Tokens are retrieved one at a time via [pollToken].
  /// Throws [NativeInferenceException] when the native bridge rejects the
  /// request.
  @override
  Future<bool> startGeneration(String prompt) async {
    _assertInitialized('startGeneration');

    final preview =
        prompt.length > 40 ? '${prompt.substring(0, 40)}…' : prompt;
    debugPrint('[NATIVE_READY] startGeneration prompt="$preview"');

    final result = _bindings!.startGeneration(
      prompt,
      LlamaNativeDefaults.nCtx, // maxTokens capped at context size
      1.0, // temperature – neutral default
    );

    if (result != 0) {
      final error = _bindings!.lastError();
      final msg = 'startGeneration failed (code=$result): $error';
      debugPrint('[NATIVE_READY] FAIL – $msg');
      throw NativeInferenceException(message: msg, code: result);
    }

    return true;
  }

  /// Returns the next token from the running generation, or `null` when EOS
  /// has been reached or no generation is active.
  @override
  Future<String?> pollToken() async {
    _assertInitialized('pollToken');

    final buf = calloc<Utf8>(LlamaNativeDefaults.tokenBufferSize);
    try {
      final result = _bindings!.pollToken(buf);
      if (result <= 0) return null; // EOS or nothing available
      return buf.toDartString();
    } finally {
      calloc.free(buf);
    }
  }

  /// Requests cancellation of any in-progress generation.
  @override
  Future<void> cancelGeneration() async {
    if (_bindings == null) return;
    _bindings!.cancel();
    debugPrint('[NATIVE_READY] Generation cancelled');
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  /// Releases the loaded model from native memory.
  @override
  Future<void> freeModel() async {
    if (_bindings == null) return;
    _bindings!.freeModel();
    debugPrint('[NATIVE_READY] Model freed');
  }

  /// Frees the model and clears all internal references.
  ///
  /// After this call [isLoaded] returns `false` and the instance must not
  /// be used again.
  @override
  Future<void> dispose() async {
    await freeModel();
    _bindings = null;
    _libraryHandle = null;
    debugPrint('[NATIVE_READY] AndroidNativeRuntimeBridge disposed');
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _assertInitialized(String method) {
    if (_bindings == null) {
      throw NativeRuntimeException(
        message:
            'AndroidNativeRuntimeBridge.$method called before initialize()',
        code: -100,
      );
    }
  }
}
