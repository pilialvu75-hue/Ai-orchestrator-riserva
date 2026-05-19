import 'dart:ffi';
import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_bindings.dart';

class LlamaFfiLibraryHandle {
  const LlamaFfiLibraryHandle({
    required this.library,
    required this.bindings,
  });

  final DynamicLibrary library;
  final LlamaBridgeBindings bindings;
}

abstract final class LlamaFfiLoader {
  static const String bridgeLibraryName = 'libllama_bridge.so';

  static const Map<Abi, String> _supportedAndroidAbis = <Abi, String>{
    Abi.androidArm64: 'arm64-v8a',
  };
  static String get _supportedAbiNames =>
      _supportedAndroidAbis.values.join(', ');
  static String get supportedAbiNames => _supportedAbiNames;

  static bool get isCurrentPlatformSupported =>
      !Platform.isAndroid || _supportedAndroidAbis.containsKey(Abi.current());

  static String get currentAbiName => Abi.current().toString().split('.').last;

  static LlamaFfiLibraryHandle? tryLoadBridgeLibrary({
    void Function(String message)? log,
  }) {
    final abi = currentAbiName;
    log?.call(
      '[FFI_LOAD_BEGIN] library=$bridgeLibraryName abi=$abi'
      ' platform=${Platform.operatingSystem}'
      ' supported_abis=$_supportedAbiNames',
    );

    if (!isCurrentPlatformSupported) {
      log?.call(
        '[FFI_LOAD_FAILURE] reason=unsupported_abi abi=$abi'
        ' supported=$_supportedAbiNames',
      );
      return null;
    }

    DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open(bridgeLibraryName);
      log?.call('[FFI_LOAD_SUCCESS] library=$bridgeLibraryName abi=$abi');
    } catch (error, stackTrace) {
      log?.call(
        '[FFI_LOAD_FAILURE] reason=open_exception'
        ' library=$bridgeLibraryName abi=$abi'
        ' error=$error',
      );
      log?.call('[FFI_LOAD_FAILURE] stackTrace=$stackTrace');
      return null;
    }

    LlamaBridgeBindings bindings;
    try {
      bindings = LlamaBridgeBindings(lib);
      log?.call(
        '[FFI_SYMBOLS_OK] library=$bridgeLibraryName abi=$abi'
        ' symbols=[llb_init_backend,llb_create_session,llb_session_start_gen,'
        'llb_session_poll_token,llb_session_cancel,llb_release_session,'
        'llb_session_last_error,llb_session_is_active]',
      );
    } catch (error, stackTrace) {
      log?.call(
        '[FFI_SYMBOLS_FAILURE] library=$bridgeLibraryName abi=$abi error=$error',
      );
      log?.call(
        '[FFI_LOAD_FAILURE] reason=symbol_bind_exception'
        ' library=$bridgeLibraryName abi=$abi'
        ' error=$error',
      );
      log?.call('[FFI_LOAD_FAILURE] stackTrace=$stackTrace');
      return null;
    }

    return LlamaFfiLibraryHandle(
      library: lib,
      bindings: bindings,
    );
  }
}
