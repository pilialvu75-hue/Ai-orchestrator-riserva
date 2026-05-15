import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_ffi_loader.dart';

/// Abstract interface for platform-specific native library loaders.
///
/// Implementations are responsible for opening the shared library and binding
/// symbols.  The interface keeps the higher-level boot pipeline free of any
/// platform-specific code.
abstract interface class NativeRuntimeLoader {
  /// Attempts to load the native library.
  ///
  /// Returns `true` on success, `false` if the library could not be found or
  /// its symbols could not be bound.
  Future<bool> tryLoad();

  /// `true` after a successful [tryLoad] call.
  bool get isLoaded;

  /// Human-readable description of the last load error, or `null` when the
  /// library loaded successfully.
  String? get loadError;
}

// ---------------------------------------------------------------------------
// Android implementation
// ---------------------------------------------------------------------------

/// Concrete [NativeRuntimeLoader] for Android that wraps
/// [LlamaFfiLoader.tryLoadBridgeLibrary].
///
/// The result of the load is stored so that downstream consumers can inspect
/// the [LlamaFfiLibraryHandle] without repeating the (expensive) library-open
/// operation.
class AndroidNativeRuntimeLoader implements NativeRuntimeLoader {
  AndroidNativeRuntimeLoader();

  LlamaFfiLibraryHandle? _handle;
  String? _loadError;

  @override
  bool get isLoaded => _handle != null;

  @override
  String? get loadError => _loadError;

  /// The library handle returned by the last successful [tryLoad] call.
  ///
  /// `null` until [tryLoad] succeeds.
  LlamaFfiLibraryHandle? get handle => _handle;

  @override
  Future<bool> tryLoad() async {
    _loadError = null;

    final result = LlamaFfiLoader.tryLoadBridgeLibrary(
      log: debugPrint,
    );

    if (result == null) {
      _loadError =
          'Failed to load ${LlamaFfiLoader.bridgeLibraryName} '
          '(ABI: ${LlamaFfiLoader.currentAbiName})';
      return false;
    }

    _handle = result;
    return true;
  }
}
