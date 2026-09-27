import 'package:flutter/foundation.dart';

/// Canonical inference-lifecycle policy.
///
/// Each duration owns one distinct boundary:
/// - startup: entering the native generation call;
/// - first token: pre-output progress;
/// - no progress: productive streaming that stops advancing;
/// - outer idle: provider-agnostic last-resort stream silence;
/// - shutdown: bounded native-session cleanup.
///
/// There is intentionally no absolute wall-clock timeout after useful content
/// starts. Productive generation remains bounded by max tokens, cancellation,
/// repetition/resource guards and the no-progress watchdog.
abstract final class InferenceLifecyclePolicy {
  static const Duration outerStreamIdleTimeout = Duration(seconds: 75);
  // LOCAL owns stricter provider-level first-token/no-progress watchdogs.
  // Keep the generic stream guard wider so it cannot win the same race.
  static const Duration outerLocalStreamIdleTimeout = Duration(minutes: 4);

  static const Duration androidStartGenerationTimeout = Duration(seconds: 60);
  static const Duration androidFirstTokenReleaseTimeout = Duration(seconds: 45);

  /// Hard ceiling used only when the native decoder proves that prompt
  /// evaluation is still advancing before the first emitted token.
  ///
  /// This avoids classifying slow CPU prompt evaluation as a dead stall while
  /// keeping genuinely idle attempts bounded by the normal 45-second release
  /// watchdog.
  static const Duration androidFirstTokenActiveProgressTimeout =
      Duration(seconds: 90);

  /// Before this policy was centralized, debug had both a 120-second
  /// first-token watchdog and a separate 90-second generation watchdog.
  /// The effective earliest deadline was therefore 90 seconds. Preserve that
  /// protection while exposing one unambiguous first-token deadline.
  static const Duration androidFirstTokenDebugTimeout = Duration(seconds: 90);
  static const Duration androidFirstTokenOverrideMax = Duration(seconds: 90);
  static const Duration androidVerificationFirstTokenTimeout =
      Duration(seconds: 5);
  static const Duration androidNoTokenProgressTimeout = Duration(seconds: 35);
  static const Duration androidSessionShutdownTimeout = Duration(seconds: 5);

  static Duration outerIdleTimeoutFor({required bool cloudOnly}) =>
      cloudOnly ? outerStreamIdleTimeout : outerLocalStreamIdleTimeout;

  static bool mayExtendAndroidFirstTokenForNativeProgress({
    required Duration elapsed,
    required int baselineDecodeCalls,
    required int currentDecodeCalls,
    bool verification = false,
  }) {
    if (verification) return false;
    if (baselineDecodeCalls < 0 || currentDecodeCalls <= baselineDecodeCalls) {
      return false;
    }
    return elapsed < androidFirstTokenActiveProgressTimeout;
  }

  static Duration androidFirstTokenTimeout({
    bool verification = false,
    bool? debugMode,
    Duration? requestedOverride,
  }) {
    if (verification) return androidVerificationFirstTokenTimeout;
    final debug = debugMode ?? kDebugMode;
    final baseline = debug
        ? androidFirstTokenDebugTimeout
        : androidFirstTokenReleaseTimeout;
    if (requestedOverride == null) return baseline;

    final boundedMs = requestedOverride.inMilliseconds
        .clamp(
          baseline.inMilliseconds,
          androidFirstTokenOverrideMax.inMilliseconds,
        )
        .toInt();
    return Duration(milliseconds: boundedMs);
  }
}

enum InferenceLifecycleTerminalReason {
  cancelled('cancelled'),
  startGenerationTimeout('start_generation_timeout'),
  firstTokenTimeout('first_token_timeout'),
  noProgressTimeout('no_progress_timeout'),
  outerStreamIdleTimeout('outer_stream_idle_timeout'),
  streamChunkLimit('stream_chunk_limit');

  const InferenceLifecycleTerminalReason(this.wireName);

  final String wireName;
}

/// Small injectable clock shared by lifecycle guards.
///
/// The clock tracks first useful content separately from arbitrary stream
/// notices. This prevents a notice from disabling the first-content deadline.
final class InferenceLifecycleClock {
  factory InferenceLifecycleClock({
    DateTime Function()? now,
  }) {
    final clock = now ?? DateTime.now;
    final startedAt = clock();
    return InferenceLifecycleClock._(
      clock,
      startedAt,
    );
  }

  InferenceLifecycleClock._(
    this._now,
    this.startedAt,
  ) : lastProgressAt = startedAt;

  final DateTime Function() _now;
  final DateTime startedAt;
  DateTime lastProgressAt;
  DateTime? firstContentAt;

  bool get hasContent => firstContentAt != null;

  Duration get elapsed => _now().difference(startedAt);

  Duration get sinceLastProgress => _now().difference(lastProgressAt);

  void markProgress({bool content = false}) {
    final current = _now();
    lastProgressAt = current;
    if (content) {
      firstContentAt ??= current;
    }
  }

  bool firstContentTimedOut(Duration timeout) =>
      !hasContent && elapsed > timeout;

  bool progressTimedOut(Duration timeout) =>
      hasContent && sinceLastProgress > timeout;
}
