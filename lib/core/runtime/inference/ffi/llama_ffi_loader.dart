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
    Abi.androidX64: 'x86_64',
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
    if (!isCurrentPlatformSupported) {
      log?.call(
        'Unsupported Android ABI: $currentAbiName. Supported: $_supportedAbiNames.',
      );
      return null;
    }

    try {
      final lib = DynamicLibrary.open(bridgeLibraryName);
      return LlamaFfiLibraryHandle(
        library: lib,
        bindings: LlamaBridgeBindings(lib),
      );
    } catch (error) {
      log?.call('Could not open $bridgeLibraryName for ABI $currentAbiName: $error');
      return null;
    }
  }
}
