import 'package:ai_orchestrator/core/runtime/runtime_provider.dart';

/// Abstract contract for a cloud-hosted agent runtime.
///
/// [CloudAgentRuntime] wraps execution that is delegated to a remote service —
/// a managed AI inference endpoint, a serverless function, or a dedicated
/// agent-runner container.
///
/// Planned backing implementations:
/// - `OpenAiCloudRuntime` — GPT-4o / Assistants API execution.
/// - `GeminiCloudRuntime` — Gemini Pro execution on Google Cloud.
/// - `CustomCloudRuntime` — generic HTTP endpoint for self-hosted runners.
///
/// Dependency rule:
///   core/runtime/ defines [CloudAgentRuntime]
///   features/cloud_ai/ provides concrete implementations
///   core/runtime/ → native/ (forbidden)
abstract class CloudAgentRuntime implements RuntimeProvider {
  /// Base URL of the cloud runtime endpoint (e.g. `'https://api.openai.com'`).
  String get endpointUrl;

  /// Returns `true` when the cloud endpoint is reachable and the API key is
  /// configured.
  ///
  /// Placeholder: always returns `false` until connectivity checks are wired up.
  Future<bool> isAvailable();

  /// The cloud provider identifier (e.g. `'openai'`, `'gemini'`, `'custom'`).
  String get providerId;

  /// Sends a keep-alive ping to the endpoint and returns round-trip latency
  /// in milliseconds.
  ///
  /// Returns `-1` when the endpoint is unreachable.
  Future<int> ping();

  // TODO(future): add authenticate() for OAuth2 / API-key refresh flows.
  // TODO(future): add Stream<RuntimeHealthEvent> watchHealth() for auto-failover.
}
