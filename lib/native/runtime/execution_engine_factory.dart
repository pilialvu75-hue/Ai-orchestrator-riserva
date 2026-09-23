import 'package:ai_orchestrator/core/config/runtime/platform_capabilities.dart';
import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';
import 'package:ai_orchestrator/native/runtime/android/android_executor.dart';
import 'package:ai_orchestrator/native/runtime/unsupported/unsupported_platform_executor.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_executor.dart';

/// Returns the [ExecutionEngine] appropriate for the current platform.
///
/// Android and Windows keep their dedicated implementations. Other hosts fail
/// closed through an explicit unsupported executor instead of masquerading as
/// Windows. This keeps Android-only dependencies isolated and makes unsupported
/// capability behavior observable and testable.
ExecutionEngine createExecutor({
  AppPlatformCapabilities? capabilities,
}) {
  final resolved = capabilities ?? AppPlatformCapabilities.current();

  return switch (resolved.host) {
    AppHostPlatform.android => AndroidExecutor(),
    AppHostPlatform.windows => WindowsExecutor(),
    _ => UnsupportedPlatformExecutor(resolved.label),
  };
}
