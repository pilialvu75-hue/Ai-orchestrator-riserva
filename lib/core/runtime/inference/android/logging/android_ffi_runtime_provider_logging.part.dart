part of '../../runtime_core.dart';

@visibleForTesting
class RuntimeLogSamplingPolicy {
  RuntimeLogSamplingPolicy({
    this.ffiPollSampleInterval = 64,
    this.runtimeTelemetrySampleInterval = 16,
  })  : assert(ffiPollSampleInterval > 0),
        assert(runtimeTelemetrySampleInterval > 0);

  final int ffiPollSampleInterval;
  final int runtimeTelemetrySampleInterval;

  int _ffiPollSampleCounter = 0;
  int _runtimeTelemetrySampleCounter = 0;

  bool shouldDrop({
    required String message,
    required bool isDebugMode,
    required bool isImmediateRuntimeTelemetry,
  }) {
    if (isDebugMode) {
      return false;
    }

    if (isImmediateRuntimeTelemetry) {
      // TOKEN_LOOP phase=start is emitted once for every local generation.
      // Always retain it and reset both release-sampling counters so the next
      // turn keeps its own early first-token and polling diagnostics.
      if (message.startsWith('[TOKEN_LOOP] phase=start')) {
        _runtimeTelemetrySampleCounter = 0;
        _ffiPollSampleCounter = 0;
        return false;
      }

      _runtimeTelemetrySampleCounter++;
      if (_runtimeTelemetrySampleCounter == 1) {
        return false;
      }

      // After event #1, retain #17, #33, ... for the default interval of 16.
      return (_runtimeTelemetrySampleCounter - 1) %
              runtimeTelemetrySampleInterval !=
          0;
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
    return _ffiPollSampleCounter != 1 &&
        _ffiPollSampleCounter % ffiPollSampleInterval != 0;
  }
}

class _AndroidFfiRuntimeLoggingService {
  /// High-frequency FFI polling events are useful for forensic diagnosis, but
  /// retaining and broadcasting every poll through RuntimeEventLog creates
  /// avoidable work on the Dart isolate.
  ///
  /// Debug builds keep the complete forensic stream. Release builds delegate
  /// high-frequency sampling to a deterministic, directly tested policy.
  static final RuntimeLogSamplingPolicy _samplingPolicy =
      RuntimeLogSamplingPolicy();

  static void log(String message) {
    final isImmediateRuntimeTelemetry =
        _AndroidFfiRuntimePollingController.isImmediateRuntimeTelemetry(
      message,
    );
    if (_samplingPolicy.shouldDrop(
      message: message,
      isDebugMode: kDebugMode,
      isImmediateRuntimeTelemetry: isImmediateRuntimeTelemetry,
    )) {
      return;
    }

    RuntimeEventLog.instance.emit(message);

    if (message.contains('FORENSIC_')) {
      return;
    }

    if (isImmediateRuntimeTelemetry) {
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

  static void logAi(String message) {
    debugPrint('[AI] $message');
  }
}
