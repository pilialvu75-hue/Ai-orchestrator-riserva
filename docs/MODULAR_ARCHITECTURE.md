# Modular Architecture — AI Orchestrator Core

## Overview

AI Orchestrator Core is structured as a **layered, modular AI operating system** built on Flutter. The goal is a stable set of architectural boundaries that allow each layer to evolve, be tested, and be replaced independently.

```
┌─────────────────────────────────────────┐
│               features/                 │  ← UI, BLoC, use-cases, feature data
│  chat │ local_ai │ cloud_ai │ projects  │
├─────────────────────────────────────────┤
│                 core/                   │  ← Contracts, orchestration, domain
│  ai/ │ memory/ │ plugins/ │ agents/    │
│  tools/ │ runtime/ │ orchestrator/     │
├─────────────────────────────────────────┤
│                native/                  │  ← Platform-specific implementations
│  runtime/ (Android, Windows executors) │
│  platform/ (Intents, Bixby)            │
└─────────────────────────────────────────┘
```

---

## Layer Responsibilities

### `lib/core/`

The stable foundation. Contains **contracts (abstract classes/interfaces)** and **orchestration logic** that is platform-agnostic.

| Sub-module | Responsibility |
|---|---|
| `core/ai/entities/` | Shared domain entities: `AiRequest`, `AiResponse`, `AiModel` |
| `core/ai/providers/` | Provider contracts: `AiRepository`, `LocalAiRepository` |
| `core/ai/` | Shared AI entities/contracts and model selection logic (`ModelManager`) |
| `core/runtime/inference/` | Unified inference contracts and runtime routing (`InferenceRequest`, `InferenceResponse`, `RuntimeInferenceProvider`, `InferenceService`) |
| `core/orchestrator/` | Central routing (`Orchestrator`), intent classification (`IntentAnalyzer`), execution contract (`ExecutionEngine`) |
| `core/memory/` | Memory provider contract (`MemoryProvider`) and implementation (`ContextWindowManager`) |
| `core/runtime/` | Runtime provider contract (`RuntimeProvider`) for platform command execution |
| `core/plugins/` | Plugin lifecycle contract (`Plugin`) and registration (`PluginRegistry`) |
| `core/agents/` | Agent contract (`Agent`, `AgentResult`) for autonomous task execution |
| `core/tools/` | Tool contract (`Tool`, `ToolResult`) for discrete callable capabilities |
| `core/database/` | SQLite persistence (`DatabaseHelper`) |
| `core/error/` | Domain failures and exceptions |
| `core/constants/` | Application-wide constants (`AppConstants`) |
| `core/services/` | Utility services (e.g. `CacheManager`) |
| `core/usecases/` | Base use-case contract (`UseCase`, `NoParams`) |

### `lib/features/`

Feature modules that implement Clean Architecture slices:
`domain (entities → repositories → use-cases) → data → presentation (BLoC, pages, widgets)`

| Feature | Responsibility |
|---|---|
| `chat/` | Conversation UI, message storage, ChatBloc |
| `cloud_ai/` | Cloud provider data sources (OpenAI, Gemini, Grok, Copilot) |
| `local_ai/` | GGUF model download, selection, offline inference UI |
| `projects/` | Project memory persistence |
| `onboarding/` | First-run setup, model registry update check |
| `voice/` | Speech-to-text and text-to-speech |
| `multimodal/` | Image capture and processing |
| `settings/` | User preference management |
| `automation/` | Task automation flows |
| `workflows/` | Multi-step workflow definitions |

Each feature's `domain/entities/` and `domain/repositories/` files that are shared with core **re-export** the canonical definitions from `core/` instead of duplicating them.

### `lib/native/`

Low-level, platform-specific implementations that fulfil `core/` contracts.

| Sub-module | Responsibility |
|---|---|
| `native/runtime/android/` | Android `ExecutionEngine` via `android_intent_plus` |
| `native/runtime/windows/` | Windows / desktop no-op `ExecutionEngine` fallback |
| `native/runtime/execution_engine_factory.dart` | Factory that selects the correct executor for the current platform |
| `native/platform/android_intent_handler.dart` | Android Intent bridge (method channel) |
| `native/platform/bixby_handler.dart` | Bixby integration (Android only) |

---

## Dependency Flow

```
main.dart / injection_container.dart
        │
        ├──▶ features/  ──▶  core/  ◀──  native/
        │        │               │
        │        └── re-exports  └── defines contracts
        │              from core
        │
        └── native/ ──▶ core/ (implements contracts, never imports features/)
```

**Allowed imports:**

| From | To | Notes |
|---|---|---|
| `features/` | `core/` | Features implement core contracts and use core use-cases |
| `native/` | `core/` | Native code implements core contracts (ExecutionEngine, RuntimeProvider) |
| `core/` | `core/` | Within-layer imports are unrestricted |
| `features/` | `features/` | Only through `core/` as intermediary (see Forbidden section) |

**Forbidden imports:**

| ❌ From | ❌ To | Why forbidden |
|---|---|---|
| `core/` | `features/` | Would create circular dependency; core must be stable |
| `core/` | `native/` | Core is platform-agnostic; native details must not leak up |
| `features/` | `native/` | Features must use core contracts, not platform-specific code |
| `native/` | `features/` | Native layer has no knowledge of feature-layer concerns |

---

## Provider Architecture

### AI Providers

```
InferenceService (core/runtime/inference/)
    ├── LocalRuntimeProvider — on-device GGUF inference runtime
    ├── CloudRuntimeProvider — cloud inference bridge
    │     └── AiRepository (core/ai/providers/)
    │           └── AiRepositoryImpl (features/cloud_ai/data/)
    └── LocalAiRepository (core/ai/providers/)
          └── LocalAiRepositoryImpl (features/local_ai/data/)
```

The unified `InferenceService` implements **local-first hybrid routing**:
1. **Local primary** — on-device GGUF inference if a validated model is selected.
2. **Cloud API** — remote provider if no valid local model is available.
3. **Auto-fallback** — retries cloud when local runtime fails before emitting output.

### Memory Providers

```
MemoryProvider (core/memory/)
    └── ContextWindowManager (core/memory/) — SQLite + in-memory window
```

### Runtime Providers

```
RuntimeProvider (core/runtime/)
    └── ExecutionEngine (core/orchestrator/) — orchestrator-level contract
          ├── AndroidExecutor (native/runtime/android/)
          └── WindowsExecutor (native/runtime/windows/)
```

---

## Plugin & Extension Architecture

### Plugins (`core/plugins/`)

```dart
abstract class Plugin {
  String get id;
  String get displayName;
  String get version;
  Future<void> initialize();
  Future<void> dispose();
}
```

Plugins are registered via `PluginRegistry.instance.register(plugin)`. Future providers, tools, and agent types should be delivered as plugins.

### Agents (`core/agents/`)

```dart
abstract class Agent {
  String get id;
  String get name;
  bool get isRunning;
  Future<AgentResult> run(String instruction);
}
```

Agents orchestrate tools, memory, and AI providers to execute multi-step tasks autonomously. Future specialisations: `CodingAgent`, `ResearchAgent`, `TaskAgent`.

### Tools (`core/tools/`)

```dart
abstract class Tool {
  String get id;
  String get name;
  String get description;
  Future<ToolResult> execute(Map<String, dynamic> params);
}
```

Tools are atomic capabilities available to agents and workflows. Planned tools: `FileTool`, `WebSearchTool`, `ShellTool`, `CodeRunnerTool`.

---

## Module Interaction Summary

```
┌──────────────────────────────────────────────────────────────┐
│  injection_container.dart (composition root)                 │
│  Wires: features → core contracts ← native implementations  │
└──────────────────────────────────────────────────────────────┘
         │                    │                    │
    features/            core/ (stable)        native/
    - BLoC               - Contracts           - Platform impls
    - UI                 - Orchestration       - No feature deps
    - Use-cases          - Domain entities     - Only core deps
    - Data sources       - Plugin registry
    ↓                    ↑                    ↑
    implements/uses  ←───┴────────────────────┘
                      (Dependency Inversion)
```

---

## Future Scalability Strategy

1. **New AI providers** — extend `AiRepositoryImpl` with a new data source and route through `CloudRuntimeProvider`.

2. **New platforms** — add a new `RuntimeProvider` implementation in `native/`. Register it in `injection_container.dart` via the factory pattern.

3. **Agent marketplace** — implement `Agent` in a plugin. Register via `PluginRegistry`. The orchestrator can discover and delegate tasks to registered agents.

4. **Tool ecosystem** — implement `Tool` in feature modules or plugins. Agents discover available tools through the registry.

5. **Memory backends** — implement `MemoryProvider` for cloud storage, vector databases, etc. Swap the implementation in DI without touching features or native.

6. **Edge / on-premise providers** — add a new repository-backed provider and route it through `CloudRuntimeProvider`.

7. **Federated / multi-agent orchestration** — the `Agent` contract supports inter-agent communication through the orchestrator. Future `MultiAgentOrchestrator` can coordinate specialist agents without coupling their implementations.

---

## Barrel Exports

| Barrel | Exports |
|---|---|
| `lib/core/core.dart` | All core contracts, entities, orchestration, services |
| `lib/features/features.dart` | All feature module barrels |
| `lib/native/native.dart` | All native platform implementations |

Consumers should import from barrel files (`package:ai_orchestrator_core/core/core.dart`) rather than reaching into subdirectories, to maintain stable import surfaces.
