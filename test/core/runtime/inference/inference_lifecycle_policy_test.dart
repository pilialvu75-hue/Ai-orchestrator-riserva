import 'package:ai_orchestrator/core/runtime/inference/inference_lifecycle_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InferenceLifecyclePolicy', () {
    test('preserves one effective Android first-token deadline per mode', () {
      expect(
        InferenceLifecyclePolicy.androidFirstTokenTimeout(
          debugMode: false,
        ),
        const Duration(seconds: 45),
      );
      expect(
        InferenceLifecyclePolicy.androidFirstTokenTimeout(
          debugMode: true,
        ),
        const Duration(seconds: 90),
      );
      expect(
        InferenceLifecyclePolicy.androidFirstTokenTimeout(
          verification: true,
          debugMode: true,
        ),
        const Duration(seconds: 5),
      );
    });

    test('bounds explicit first-token overrides without weakening watchdogs', () {
      expect(
        InferenceLifecyclePolicy.androidFirstTokenTimeout(
          debugMode: false,
          requestedOverride: const Duration(seconds: 75),
        ),
        const Duration(seconds: 75),
      );
      expect(
        InferenceLifecyclePolicy.androidFirstTokenTimeout(
          debugMode: false,
          requestedOverride: const Duration(seconds: 10),
        ),
        const Duration(seconds: 45),
      );
      expect(
        InferenceLifecyclePolicy.androidFirstTokenTimeout(
          debugMode: false,
          requestedOverride: const Duration(minutes: 3),
        ),
        const Duration(seconds: 90),
      );
      expect(
        InferenceLifecyclePolicy.androidFirstTokenTimeout(
          verification: true,
          debugMode: false,
          requestedOverride: const Duration(seconds: 75),
        ),
        const Duration(seconds: 5),
      );
    });

    test('keeps lifecycle boundaries distinct', () {
      expect(
        InferenceLifecyclePolicy.androidStartGenerationTimeout,
        const Duration(seconds: 60),
      );
      expect(
        InferenceLifecyclePolicy.androidNoTokenProgressTimeout,
        const Duration(seconds: 35),
      );
      expect(
        InferenceLifecyclePolicy.androidSessionShutdownTimeout,
        const Duration(seconds: 5),
      );
      expect(
        InferenceLifecyclePolicy.outerStreamIdleTimeout,
        const Duration(seconds: 75),
      );
      expect(
        InferenceLifecyclePolicy.outerLocalStreamIdleTimeout,
        const Duration(minutes: 4),
      );
      expect(
        InferenceLifecyclePolicy.outerIdleTimeoutFor(cloudOnly: true),
        const Duration(seconds: 75),
      );
      expect(
        InferenceLifecyclePolicy.outerIdleTimeoutFor(cloudOnly: false),
        const Duration(minutes: 4),
      );
    });
  });

  group('InferenceLifecycleClock', () {
    test('first-content deadline is not reset by non-content progress', () {
      var now = DateTime.utc(2026, 9, 23, 12);
      final clock = InferenceLifecycleClock(now: () => now);

      now = now.add(const Duration(seconds: 20));
      clock.markProgress();
      expect(clock.hasContent, isFalse);

      now = now.add(const Duration(seconds: 26));
      expect(
        clock.firstContentTimedOut(const Duration(seconds: 45)),
        isTrue,
      );
    });

    test('productive content switches the clock to no-progress semantics', () {
      var now = DateTime.utc(2026, 9, 23, 12);
      final clock = InferenceLifecycleClock(now: () => now);

      now = now.add(const Duration(seconds: 10));
      clock.markProgress(content: true);
      expect(clock.hasContent, isTrue);
      expect(
        clock.firstContentTimedOut(const Duration(seconds: 5)),
        isFalse,
      );

      now = now.add(const Duration(seconds: 34));
      expect(
        clock.progressTimedOut(const Duration(seconds: 35)),
        isFalse,
      );

      now = now.add(const Duration(seconds: 2));
      expect(
        clock.progressTimedOut(const Duration(seconds: 35)),
        isTrue,
      );
    });

    test('any native progress refreshes the no-progress clock', () {
      var now = DateTime.utc(2026, 9, 23, 12);
      final clock = InferenceLifecycleClock(now: () => now);

      clock.markProgress(content: true);
      now = now.add(const Duration(seconds: 30));
      clock.markProgress();
      now = now.add(const Duration(seconds: 30));

      expect(
        clock.progressTimedOut(const Duration(seconds: 35)),
        isFalse,
      );
    });
  });

  group('active native first-token progress', () {
    test('extends release wait when decoder advances after soft deadline', () {
      expect(
        InferenceLifecyclePolicy.mayExtendAndroidFirstTokenForNativeProgress(
          elapsed: const Duration(seconds: 51),
          baselineDecodeCalls: 4,
          currentDecodeCalls: 10,
        ),
        isTrue,
      );
    });

    test('does not extend an actually idle decoder', () {
      expect(
        InferenceLifecyclePolicy.mayExtendAndroidFirstTokenForNativeProgress(
          elapsed: const Duration(seconds: 51),
          baselineDecodeCalls: 4,
          currentDecodeCalls: 4,
        ),
        isFalse,
      );
    });

    test('keeps active progress bounded by the hard ceiling', () {
      expect(
        InferenceLifecyclePolicy.mayExtendAndroidFirstTokenForNativeProgress(
          elapsed: const Duration(seconds: 91),
          baselineDecodeCalls: 4,
          currentDecodeCalls: 12,
        ),
        isFalse,
      );
    });

    test('never extends forensic verification', () {
      expect(
        InferenceLifecyclePolicy.mayExtendAndroidFirstTokenForNativeProgress(
          elapsed: const Duration(seconds: 6),
          baselineDecodeCalls: 0,
          currentDecodeCalls: 1,
          verification: true,
        ),
        isFalse,
      );
    });
  });

  test('terminal reasons are stable wire values', () {
    expect(
      InferenceLifecycleTerminalReason.firstTokenTimeout.wireName,
      'first_token_timeout',
    );
    expect(
      InferenceLifecycleTerminalReason.noProgressTimeout.wireName,
      'no_progress_timeout',
    );
    expect(
      InferenceLifecycleTerminalReason.outerStreamIdleTimeout.wireName,
      'outer_stream_idle_timeout',
    );
  });
}
