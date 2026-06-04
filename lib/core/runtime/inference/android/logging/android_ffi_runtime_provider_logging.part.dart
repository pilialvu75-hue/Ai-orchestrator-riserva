part of '../../runtime_core.dart';


class _AndroidFfiRuntimeLoggingService {
  static void log(String message) {
    RuntimeEventLog.instance.emit(message);
    if (message.contains('FORENSIC_')) return;
    if (_AndroidFfiRuntimePollingController.isImmediateRuntimeTelemetry(message)) {
      final safeMessage =
          message.length > 220 ? message.substring(0, 220) : message;
      debugPrint('[${AndroidFfiRuntimeProvider._logTag}] $safeMessage');
      return;
    }
    AndroidFfiRuntimeProvider._printCounter++;
    if (AndroidFfiRuntimeProvider._printCounter % 10 == 0) {
      final safeMessage =
          message.length > 220 ? message.substring(0, 220) : message;
      debugPrint('[${AndroidFfiRuntimeProvider._logTag}] $safeMessage');
    }
  }

  static void logAi(String message) {
    debugPrint('[AI] $message');
  }
}
