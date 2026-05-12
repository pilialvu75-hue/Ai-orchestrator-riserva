# lib/core/plugins/

Plugin system for extending AI Orchestrator with third-party capabilities.

The plugin architecture allows external modules to register new:
- AI providers / backends
- Tools
- Agents
- UI widgets

## Planned Contents

- `plugin.dart` — Abstract `Plugin` interface
- `plugin_registry.dart` — Singleton registry for loaded plugins
- `plugin_loader.dart` — Dynamic plugin loading logic
