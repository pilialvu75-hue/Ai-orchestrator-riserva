import 'dart:io';

import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';
import 'package:ai_orchestrator/native/runtime/android/android_executor.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_executor.dart';

/// Returns the [ExecutionEngine] appropriate for the current platform.
///
/// On Android an [AndroidExecutor] is returned, which can launch real apps.
/// On all other platforms (Windows, Linux, macOS, iOS) a [WindowsExecutor]
/// is returned, providing a safe no-op fallback that keeps builds green.
/// [WindowsExecutor] acts as a generic fallback for all non-Android targets.
ExecutionEngine createExecutor() {
  if (Platform.isAndroid) {
    return AndroidExecutor();
  }
  return WindowsExecutor();
}
