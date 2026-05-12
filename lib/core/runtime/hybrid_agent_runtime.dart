import 'package:ai_orchestrator/core/runtime/local_agent_runtime.dart';
import 'package:ai_orchestrator/core/runtime/cloud_agent_runtime.dart';
import 'package:ai_orchestrator/core/runtime/runtime_provider.dart';

/// Routing policy for [HybridAgentRuntime].
enum HybridRoutingPolicy {
  /// Always prefer local execution; fall back to cloud only when local is
  /// unavailable or has no capacity.
  localFirst,

  /// Always prefer cloud execution; fall back to local on connectivity failure.
  cloudFirst,

  /// Run the task on whichever runtime responds first.
  ///
  /// Results from the slower runtime are discarded.
  /// (Placeholder — not yet implemented.)
  race,
}

/// Abstract contract for a hybrid agent runtime that combines local and cloud
/// execution with automatic fallback.
///
/// [HybridAgentRuntime] is the **intended design** for production deployments
/// once concrete implementations are wired up.  It applies a
/// [HybridRoutingPolicy] to decide whether each command runs locally or in the
/// cloud, mirroring the local-first routing already present in `InferenceService`.
///
/// Routing tiers:
/// 1. **Local primary** (`localFirst` policy) — run on [localRuntime] when
///    available and within capacity.
/// 2. **Cloud primary** (`cloudFirst` policy) — run on [cloudRuntime] when
///    connectivity is confirmed.
/// 3. **Automatic fallback** — if the preferred tier fails, transparently
///    retries on the other tier.
///
/// Dependency rule:
///   core/runtime/ defines [HybridAgentRuntime]
///   features/ / injection_container.dart wire concrete implementations
///   core/runtime/ → core/ only (no native/ imports here)
abstract class HybridAgentRuntime implements RuntimeProvider {
  /// The local execution backend.
  LocalAgentRuntime get localRuntime;

  /// The cloud execution backend.
  CloudAgentRuntime get cloudRuntime;

  /// Active routing policy.
  HybridRoutingPolicy get policy;

  /// Executes [command] according to the active [policy].
  ///
  /// Concrete implementations should apply the following logic:
  /// 1. If `policy == localFirst`: try [localRuntime.execute]; on failure or
  ///    `!localRuntime.isSupported`, fall back to [cloudRuntime.execute].
  /// 2. If `policy == cloudFirst`: try [cloudRuntime.execute]; on failure,
  ///    fall back to [localRuntime.execute].
  /// 3. If `policy == race`: run both concurrently, return first result,
  ///    cancel the other.
  @override
  Future<String> execute(String command);

  /// Returns `true` when at least one of the two underlying runtimes is
  /// available.
  @override
  bool get isSupported;

  // TODO(future): add switchPolicy(HybridRoutingPolicy) at runtime.
  // TODO(future): add telemetry(String command) to record which tier handled each call.
}
