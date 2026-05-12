import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';

/// Windows (and generic desktop) implementation of [ExecutionEngine].
///
/// Device commands are not supported on Windows; this class provides a safe
/// fallback so that Windows builds never crash when a command intent is
/// detected.
class WindowsExecutor implements ExecutionEngine {
  @override
  Future<String> execute(String input) async {
    return 'Comandi non supportati su Windows';
  }
}
