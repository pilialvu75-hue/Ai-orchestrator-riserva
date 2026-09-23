import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';

/// Explicit fail-closed executor for hosts that do not implement device-command
/// execution.
///
/// This is intentionally not a Windows implementation: callers receive the
/// actual host label instead of a misleading Windows fallback.
final class UnsupportedPlatformExecutor implements ExecutionEngine {
  const UnsupportedPlatformExecutor(this.platformLabel);

  final String platformLabel;

  @override
  Future<String> execute(String input) async {
    return 'Comandi non supportati su $platformLabel';
  }
}
