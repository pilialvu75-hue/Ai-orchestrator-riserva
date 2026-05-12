import 'package:ai_orchestrator/core/runtime/runtime_provider.dart';

/// Abstract contract for a local (on-device) agent runtime.
///
/// [LocalAgentRuntime] wraps platform-level execution that happens entirely
/// on the user's device — no network calls, no external services.
///
/// Planned backing implementations:
/// - Android: `AndroidExecutor` via `android_intent_plus`.
/// - Desktop: shell-command executor (Windows / macOS / Linux).
/// - WASM sandbox: in-browser execution (future).
///
/// Dependency rule:
///   core/runtime/ defines [LocalAgentRuntime]
///   native/runtime/ provides concrete implementations
///   core/runtime/ → native/ (forbidden — native implements core, not vice-versa)
abstract class LocalAgentRuntime implements RuntimeProvider {
  /// Human-readable label for this local runtime (e.g. `'Android Local'`).
  String get label;

  /// Returns `true` when the device has enough free resources to start
  /// a new agent task.
  ///
  /// Placeholder: always returns `true` until resource monitoring is wired up.
  bool get hasCapacity;

  /// Optional path to a local model file that this runtime can load for
  /// on-device inference.
  ///
  /// `null` when no local model is configured.
  String? get localModelPath;

  // TODO(future): add ResourceUsage get currentUsage for CPU/RAM monitoring.
  // TODO(future): add isolateExecute(String fn) for Dart Isolate-based tasks.
}
