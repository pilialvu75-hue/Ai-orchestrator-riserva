part of '../../runtime_core.dart';

class _AndroidFfiRuntimeLoggingService {
  /// High-frequency FFI polling events are useful for forensic diagnosis, but
  /// retaining and broadcasting every poll through RuntimeEventLog creates
  /// avoidable work on the Dart isolate.
  ///
  /// Debug builds keep the complete forensic stream.
  /// Release builds keep the first sample, periodic samples, and terminal
  /// results so important runtime failures remain diagnosable without flooding
  /// the event log.
  static const int _ffiPollSampleInterval = 64;

  static int _ffiPollSampleCounter = 0;

  static void log(String message) {
    if (_shouldDropHighFrequencyFfiEvent(message)) {
      return;
    }

    RuntimeEventLog.instance.emit(message);

    if (message.contains('FORENSIC_')) {
      return;
    }

    if (_AndroidFfiRuntimePollingController.isImmediateRuntimeTelemetry(
      message,
    )) {
      final safeMessage =
          message.length > 220 ? message.substring(0, 220) : message;
      debugPrint(
        '[${AndroidFfiRuntimeProvider._logTag}] $safeMessage',
      );
      return;
    }

    AndroidFfiRuntimeProvider._printCounter++;

    if (AndroidFfiRuntimeProvider._printCounter % 10 == 0) {
      final safeMessage =
          message.length > 220 ? message.substring(0, 220) : message;
      debugPrint(
        '[${AndroidFfiRuntimeProvider._logTag}] $safeMessage',
      );
    }
  }

  static bool _shouldDropHighFrequencyFfiEvent(String message) {
    // During development keep the complete forensic stream available.
    if (kDebugMode) {
      return false;
    }

    final isPollEnter = message.startsWith('[FFI_CALLBACK_ENTER]');
    final isPollPayload = message.startsWith('[FFI_CALLBACK_PAYLOAD]');

    if (!isPollEnter && !isPollPayload) {
      return false;
    }

    // Never suppress successful token delivery, EOS, cancellation, or errors.
    if (message.contains('status=1') ||
        message.contains('status=2') ||
        message.contains('status=-1') ||
        message.contains('status=-99')) {
      return false;
    }

    _ffiPollSampleCounter++;

    // Keep the first high-frequency event and then one sample every N events.
    // This dramatically reduces RuntimeEventLog/broadcast traffic in release
    // builds while preserving enough information to diagnose a stalled loop.
    return _ffiPollSampleCounter != 1 &&
        _ffiPollSampleCounter % _ffiPollSampleInterval != 0;
  }

  static void logAi(String message) {
    debugPrint('[AI] $message');
  }
}
