import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/android_ffi_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';

/// Returns the [LocalRuntimeProvider] appropriate for the current platform.
///
/// **Android** → [AndroidFfiRuntimeProvider]
///   Uses [dart:ffi] to load [libllama_bridge.so].  Executable-process spawning is
///   not available on Android, so all local inference must go through the
///   shared-library path.
///
/// **Desktop (Windows / macOS / Linux)** → [LocalRuntimeProvider]
///   Spawns the llama.cpp CLI executable via [Process.start] as before.
LocalRuntimeProvider createLocalRuntimeProvider() {
  if (Platform.isAndroid) {
    return AndroidFfiRuntimeProvider();
  }
  return LocalRuntimeProvider();
}
