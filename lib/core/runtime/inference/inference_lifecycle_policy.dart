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

  static const Duration androidStartGenerationTimeout = Duration(seconds: 60);
  static const Duration androidFirstTokenReleaseTimeout = Duration(seconds: 45);

  /// Before this policy was centralized, debug had both a 120-second
  /// first-token watchdog and a separate 90-second generation watchdog.
  /// The effective earliest deadline was therefore 90 seconds. Preserve that
  /// protection while exposing one unambiguous first-token deadline.
  static const Duration androidFirstTokenDebugTimeout = Duration(seconds: 90);
  static const Duration androidVerificationFirstTokenTimeout =
      Duration(seconds: 5);
  static const Duration androidNoTokenProgressTimeout = Duration(seconds: 35);
  static const Duration androidSessionShutdownTimeout = Duration(seconds: 5);

  static Duration androidFirstTokenTimeout({
    bool verification = false,
    bool? debugMode,
  }) {
    if (verification) return androidVerificationFirstTokenTimeout;
    final debug = debugMode ?? kDebugMode;
    return debug
        ? androidFirstTokenDebugTimeout
        : androidFirstTokenReleaseTimeout;
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
