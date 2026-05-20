import 'dart:io';
import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/runtime/inference/android_ffi_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_state_machine.dart';

int _providerCreateCount = 0;
bool _providerCreateInProgress = false;

/// Returns the [LocalRuntimeProvider] appropriate for the current platform.
///
/// **Android** → [AndroidFfiRuntimeProvider]
///   Uses [dart:ffi] to load [libllama_bridge.so].  Executable-process spawning is
///   not available on Android, so all local inference must go through the
///   shared-library path.
///
/// **Desktop (Windows / macOS / Linux)** → [LocalRuntimeProvider]
///   Spawns the llama.cpp CLI executable via [Process.start] as before.
LocalRuntimeProvider createLocalRuntimeProvider({
  RuntimeStateMachine? runtimeStateMachine,
  bool Function()? developerModeProvider,
}) {
  if (_providerCreateInProgress) {
    debugPrint(
      '[RUNTIME_INIT_RECURSION] scope=local_runtime_provider_factory.createLocalRuntimeProvider',
    );
  }
  _providerCreateInProgress = true;
  try {
    _providerCreateCount++;
  if (Platform.isAndroid) {
    debugPrint('[RUNTIME_PATH] platform=android provider=AndroidFfiRuntimeProvider');
    debugPrint(
      '[RUNTIME_PROVIDER_BRANCH] provider=AndroidFfiRuntimeProvider '
      'runtime_mode=local branch=session_api provider_path_selected=android',
    );
    final provider = AndroidFfiRuntimeProvider(
      runtimeStateMachine: runtimeStateMachine,
      developerModeProvider: developerModeProvider,
    );
    debugPrint(
      '[PROVIDER_CREATE] type=AndroidFfiRuntimeProvider hash=${provider.hashCode.toRadixString(16)} create_count=$_providerCreateCount',
    );
    return provider;
  }
  debugPrint('[RUNTIME_PATH] platform=desktop provider=LocalRuntimeProvider');
  debugPrint(
    '[RUNTIME_PROVIDER_BRANCH] provider=LocalRuntimeProvider '
    'runtime_mode=desktop branch=cli_process provider_path_selected=desktop',
  );
  final provider = LocalRuntimeProvider(
    developerModeProvider: developerModeProvider,
  );
  debugPrint(
    '[PROVIDER_CREATE] type=LocalRuntimeProvider hash=${provider.hashCode.toRadixString(16)} create_count=$_providerCreateCount',
  );
  return provider;
  } finally {
    _providerCreateInProgress = false;
  }
}
