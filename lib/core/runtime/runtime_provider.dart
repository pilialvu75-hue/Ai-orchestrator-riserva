/// Contract for platform-level runtime providers.
///
/// [RuntimeProvider] abstracts over platform-specific execution engines:
/// - Android: dispatches Intents via [AndroidExecutor].
/// - Desktop (Windows / Linux / macOS): executes shell commands or no-ops.
/// - Future: WebAssembly sandboxes, remote agent runners, etc.
///
/// The concrete [ExecutionEngine] implementations in `native/runtime/` satisfy
/// this contract.  The orchestration layer depends only on [RuntimeProvider];
/// it must never import from `native/` directly.
///
/// Dependency rule:
///   core/runtime/ ← native/runtime/ (native implements core contract)
///   features/     → core/runtime/   (features call through core)
///   features/    -/→ native/        (forbidden direct access)
abstract class RuntimeProvider {
  /// Executes [command] and returns a human-readable result string.
  ///
  /// Implementations should catch all platform exceptions and return a
  /// descriptive error message rather than rethrowing.
  Future<String> execute(String command);

  /// Returns `true` when this runtime is available on the current platform.
  bool get isSupported;

  // TODO(future): add executeAsync() for long-running background tasks with
  //               progress callbacks.
  // TODO(future): add cancel(String taskId) for cancellable operations.
}
