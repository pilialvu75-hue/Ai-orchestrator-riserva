/// Abstract interface that isolates all native FFI interactions from the
/// rest of the runtime.
///
/// Concrete implementations exist per-platform (e.g.
/// [AndroidNativeRuntimeBridge]).  Non-Android builds can supply a no-op
/// or stub implementation so that the higher-level layers compile and run
/// without an FFI library present.
abstract interface class NativeRuntimeBridge {
  /// `true` when the native library has been loaded and its symbols bound.
  bool get isLoaded;

  /// Loads the native library and binds all required symbols.
  ///
  /// Must be called before any other method.  Returns `true` on success.
  Future<bool> initialize();

  /// Loads the model at [modelPath] into the native runtime.
  ///
  /// [nCtx]     — KV-cache context size (tokens).
  /// [nThreads] — CPU thread count used by the native runtime.
  Future<bool> loadModel(
    String modelPath, {
    int nCtx,
    int nThreads,
  });

  /// Begins streaming generation for [prompt].
  ///
  /// Tokens are retrieved one at a time via [pollToken].
  Future<bool> startGeneration(String prompt);

  /// Returns the next token produced by the running generation, or `null`
  /// when generation has finished (EOS) or has not started yet.
  Future<String?> pollToken();

  /// Requests cancellation of any in-progress generation.
  Future<void> cancelGeneration();

  /// Releases the loaded model from native memory.
  Future<void> freeModel();

  /// Frees all native resources and resets the bridge to an uninitialised
  /// state.  The instance should not be used after this call.
  Future<void> dispose();
}

// ---------------------------------------------------------------------------
// State snapshot
// ---------------------------------------------------------------------------

/// Immutable snapshot of the current native bridge state.
///
/// Intended for diagnostics, logging, and the healthcheck pipeline.
class NativeRuntimeBridgeState {
  const NativeRuntimeBridgeState({
    required this.isLibraryLoaded,
    required this.isModelLoaded,
    required this.isGenerating,
    this.lastError,
  });

  /// `true` when the native library has been opened and symbols bound.
  final bool isLibraryLoaded;

  /// `true` when a model is currently resident in native memory.
  final bool isModelLoaded;

  /// `true` while a token-generation request is active.
  final bool isGenerating;

  /// The last error string reported by the native bridge, or `null` when
  /// no error has occurred.
  final String? lastError;

  /// Returns a copy with the specified fields replaced.
  ///
  /// To explicitly clear [lastError], pass `clearLastError: true`.
  NativeRuntimeBridgeState copyWith({
    bool? isLibraryLoaded,
    bool? isModelLoaded,
    bool? isGenerating,
    String? lastError,
    bool clearLastError = false,
  }) {
    return NativeRuntimeBridgeState(
      isLibraryLoaded: isLibraryLoaded ?? this.isLibraryLoaded,
      isModelLoaded: isModelLoaded ?? this.isModelLoaded,
      isGenerating: isGenerating ?? this.isGenerating,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }

  @override
  String toString() =>
      'NativeRuntimeBridgeState('
      'libraryLoaded=$isLibraryLoaded, '
      'modelLoaded=$isModelLoaded, '
      'generating=$isGenerating, '
      'lastError=$lastError)';
}
