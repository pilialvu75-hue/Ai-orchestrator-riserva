/// Base class for all exceptions originating in the native runtime layer.
///
/// Subclasses specialise the error category so that catch-blocks can be
/// precisely targeted and logged.
class NativeRuntimeException implements Exception {
  const NativeRuntimeException({
    required this.message,
    required this.code,
  });

  /// Human-readable description of what went wrong.
  final String message;

  /// Machine-readable error code (e.g. a native errno or a sentinel value
  /// returned by the FFI bridge).
  final int code;

  @override
  String toString() =>
      '${runtimeType.toString()}(code=$code): $message';
}

// ---------------------------------------------------------------------------
// Concrete exception types
// ---------------------------------------------------------------------------

/// Thrown when the native shared library (e.g. `libllama_bridge.so`) cannot
/// be located or opened.
class NativeLibraryNotFoundException extends NativeRuntimeException {
  const NativeLibraryNotFoundException({
    required super.message,
    super.code = -1,
  });
}

/// Thrown when required symbols cannot be resolved in the loaded library.
class NativeSymbolBindingException extends NativeRuntimeException {
  const NativeSymbolBindingException({
    required super.message,
    super.code = -2,
  });
}

/// Thrown when the native bridge fails to load the model file.
class NativeModelLoadException extends NativeRuntimeException {
  const NativeModelLoadException({
    required super.message,
    super.code = -3,
  });
}

/// Thrown when the native bridge cannot allocate or initialise the inference
/// context.
class NativeContextAllocationException extends NativeRuntimeException {
  const NativeContextAllocationException({
    required super.message,
    super.code = -4,
  });
}

/// Thrown when a token-generation call to the native bridge fails.
class NativeInferenceException extends NativeRuntimeException {
  const NativeInferenceException({
    required super.message,
    super.code = -5,
  });
}

/// Thrown when a new session is requested while a generation is already
/// active and cannot be interrupted.
class NativeSessionConflictException extends NativeRuntimeException {
  const NativeSessionConflictException({
    required super.message,
    super.code = -6,
  });
}
