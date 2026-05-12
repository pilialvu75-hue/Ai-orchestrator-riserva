/// Base contract for all AI Orchestrator plugins.
///
/// A plugin is a self-contained unit that extends the platform with new
/// capabilities: additional AI backends, tools, UI widgets, agent types, etc.
///
/// Plugins are registered and managed by [PluginRegistry].
///
/// Dependency rule:
///   core/plugins/ ← external packages / feature modules (they provide plugins)
///   core/plugins/ → core/ only (no native/ or features/ imports here)
abstract class Plugin {
  /// Unique, stable identifier for this plugin (e.g. `'openai_provider'`).
  String get id;

  /// Human-readable display name shown in the plugin catalogue.
  String get displayName;

  /// Semantic version string (e.g. `'1.0.0'`).
  String get version;

  /// Called once when the plugin is loaded into [PluginRegistry].
  ///
  /// Implementations should set up resources (HTTP clients, DB handles, etc.)
  /// and throw on unrecoverable initialisation errors.
  Future<void> initialize();

  /// Called when the plugin is unregistered from [PluginRegistry].
  ///
  /// Implementations should release all resources acquired in [initialize].
  Future<void> dispose();

  // TODO(future): add List<Tool> get tools to expose plugin-provided tools.
  // TODO(future): add List<Agent> get agents to expose plugin-provided agents.
}
