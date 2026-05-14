/// Represents the current operational health of the application runtime.
///
/// The orchestrator and health-check subsystems use this enum to
/// communicate degraded states without exposing implementation details
/// to the UI or business layers.
///
/// State transitions are unidirectional during a session (normal →
/// degraded → offline → emergency) but can recover across cold starts.
enum SafeModeState {
  /// All systems fully operational.
  normal,

  /// One or more non-critical subsystems have failed or are unavailable
  /// (e.g. remote config unreachable, telemetry queue full).
  /// Core functionality is still intact.
  degraded,

  /// Network connectivity is absent and cloud-dependent features are
  /// disabled. Local-only mode is active.
  offline,

  /// A critical subsystem failure has been detected. The app may limit
  /// or disable features to preserve data integrity.
  emergency;

  /// Returns `true` when the state represents any kind of impairment.
  bool get isImpaired => this != SafeModeState.normal;

  /// Returns `true` when core AI inference should be restricted to
  /// local-only execution regardless of user preference.
  bool get enforceLocalOnly =>
      this == SafeModeState.offline || this == SafeModeState.emergency;
}
