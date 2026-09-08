import 'package:ai_orchestrator/core/runtime/inference/runtime_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RuntimeLogSamplingPolicy', () {
    test('debug mode retains the complete telemetry stream', () {
      final policy = RuntimeLogSamplingPolicy(
        runtimeTelemetrySampleInterval: 2,
      );

      for (var i = 0; i < 8; i++) {
        expect(
          policy.shouldDrop(
            message: '[TOKEN_STREAM] piece=$i',
            isDebugMode: true,
            isImmediateRuntimeTelemetry: true,
          ),
          isFalse,
        );
      }
    });

    test('release telemetry keeps generation boundary and exact interval', () {
      final policy = RuntimeLogSamplingPolicy(
        runtimeTelemetrySampleInterval: 4,
      );

      expect(
        policy.shouldDrop(
          message: '[TOKEN_LOOP] phase=start max_tokens=128',
          isDebugMode: false,
          isImmediateRuntimeTelemetry: true,
        ),
        isFalse,
      );

      final dropped = <bool>[];
      for (var i = 1; i <= 9; i++) {
        dropped.add(
          policy.shouldDrop(
            message: '[TOKEN_STREAM] piece=$i',
            isDebugMode: false,
            isImmediateRuntimeTelemetry: true,
          ),
        );
      }

      // Event #1 is retained, then #5 and #9 for an interval of four.
      expect(
        dropped,
        <bool>[false, true, true, true, false, true, true, true, false],
      );
    });

    test('new generation resets sampling so early diagnostics are retained', () {
      final policy = RuntimeLogSamplingPolicy(
        runtimeTelemetrySampleInterval: 4,
      );

      expect(
        policy.shouldDrop(
          message: '[TOKEN_LOOP] phase=start max_tokens=128',
          isDebugMode: false,
          isImmediateRuntimeTelemetry: true,
        ),
        isFalse,
      );
      expect(
        policy.shouldDrop(
          message: '[FIRST_TOKEN_WAIT] waited_ms=250',
          isDebugMode: false,
          isImmediateRuntimeTelemetry: true,
        ),
        isFalse,
      );
      expect(
        policy.shouldDrop(
          message: '[FIRST_TOKEN_WAIT] waited_ms=500',
          isDebugMode: false,
          isImmediateRuntimeTelemetry: true,
        ),
        isTrue,
      );

      expect(
        policy.shouldDrop(
          message: '[TOKEN_LOOP] phase=start max_tokens=128',
          isDebugMode: false,
          isImmediateRuntimeTelemetry: true,
        ),
        isFalse,
      );
      expect(
        policy.shouldDrop(
          message: '[FIRST_TOKEN_WAIT] waited_ms=250',
          isDebugMode: false,
          isImmediateRuntimeTelemetry: true,
        ),
        isFalse,
      );
    });

    test('release FFI polling keeps first sample and terminal results', () {
      final policy = RuntimeLogSamplingPolicy(ffiPollSampleInterval: 4);

      expect(
        policy.shouldDrop(
          message: '[FFI_CALLBACK_ENTER] status=0',
          isDebugMode: false,
          isImmediateRuntimeTelemetry: false,
        ),
        isFalse,
      );
      expect(
        policy.shouldDrop(
          message: '[FFI_CALLBACK_PAYLOAD] status=0',
          isDebugMode: false,
          isImmediateRuntimeTelemetry: false,
        ),
        isTrue,
      );
      expect(
        policy.shouldDrop(
          message: '[FFI_CALLBACK_PAYLOAD] status=1 token=42',
          isDebugMode: false,
          isImmediateRuntimeTelemetry: false,
        ),
        isFalse,
      );
      expect(
        policy.shouldDrop(
          message: '[FFI_CALLBACK_PAYLOAD] status=-99 error=true',
          isDebugMode: false,
          isImmediateRuntimeTelemetry: false,
        ),
        isFalse,
      );
    });
  });
}
