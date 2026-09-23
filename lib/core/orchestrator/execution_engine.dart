/// Contract for executing device/system commands.
///
/// Concrete implementations are selected behind a platform-capability boundary.
/// Unsupported hosts must fail closed explicitly rather than borrowing another
/// platform's implementation.
abstract class ExecutionEngine {
  /// Executes [input] and returns a human-readable result string.
  Future<String> execute(String input);
}
