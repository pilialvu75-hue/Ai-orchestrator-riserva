import 'package:ai_orchestrator/core/plugins/plugin.dart';

/// Singleton registry for loaded [Plugin] instances.
///
/// All plugin interactions should go through this registry to ensure
/// lifecycle methods (initialize / dispose) are called consistently.
///
/// Usage:
/// ```dart
/// await PluginRegistry.instance.register(MyPlugin());
/// final plugin = PluginRegistry.instance.get('my_plugin');
/// ```
class PluginRegistry {
  PluginRegistry._();

  /// The global singleton instance.
  static final PluginRegistry instance = PluginRegistry._();

  final Map<String, Plugin> _plugins = {};

  // ── Registration ────────────────────────────────────────────────────────────

  /// Registers [plugin] and calls its [Plugin.initialize] lifecycle hook.
  ///
  /// Throws if a plugin with the same [Plugin.id] is already registered.
  Future<void> register(Plugin plugin) async {
    if (_plugins.containsKey(plugin.id)) {
      throw StateError(
        'Plugin "${plugin.id}" is already registered. '
        'Call unregister() before registering a new instance.',
      );
    }
    await plugin.initialize();
    _plugins[plugin.id] = plugin;
  }

  // ── Lookup ──────────────────────────────────────────────────────────────────

  /// Returns the registered [Plugin] for [id], or `null` if not found.
  Plugin? get(String id) => _plugins[id];

  /// Returns an unmodifiable view of all registered plugins, keyed by id.
  Map<String, Plugin> get all => Map.unmodifiable(_plugins);

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  /// Calls [Plugin.dispose] and removes the plugin with [id] from the registry.
  ///
  /// Does nothing if no plugin with [id] is registered.
  Future<void> unregister(String id) async {
    final plugin = _plugins.remove(id);
    await plugin?.dispose();
  }

  /// Disposes and removes all registered plugins.
  Future<void> clear() async {
    for (final id in List<String>.from(_plugins.keys)) {
      await unregister(id);
    }
  }

  // TODO(future): add plugin discovery via reflection / package_info_plus so
  //               plugins can be auto-detected without manual registration.
}
