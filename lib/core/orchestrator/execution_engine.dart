/// Contract for executing device/system commands.
///
/// Concrete implementations are platform-specific:
/// - [AndroidExecutor] — uses android_intent_plus to launch real apps.
/// - [WindowsExecutor] — safe no-op fallback for desktop builds.
abstract class ExecutionEngine {
  /// Executes [input] and returns a human-readable result string.
  Future<String> execute(String input);
}
