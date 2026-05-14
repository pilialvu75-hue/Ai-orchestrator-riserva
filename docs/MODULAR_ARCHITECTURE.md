# Modular Architecture

This repository implements the stable architectural base of AI-Orchestrator as a **modular offline-first cognitive orchestration platform**.

## 1. Architectural purpose

The architecture is designed to keep five concerns separable:

1. **interaction** — UI, BLoC, workflows
2. **reasoning/orchestration** — routing, planning, execution strategy
3. **runtime execution** — local inference, cloud inference, platform execution
4. **state and memory** — chat history, project memory, sync records, document chunks
5. **platform integration** — Android bridges, native libraries, future desktop adapters

The platform must remain evolvable without forcing every subsystem to depend on every other subsystem.

## 2. Layer map

```text
┌─────────────────────────────────────────────────────────────┐
│ UI / Presentation                                           │
│ features/*/presentation, widgets, pages, blocs             │
├─────────────────────────────────────────────────────────────┤
│ Feature/Application Layer                                   │
│ features/*/domain + data                                    │
├─────────────────────────────────────────────────────────────┤
│ Core Platform Logic                                         │
│ core/orchestrator, core/runtime, core/memory, core/sync,   │
│ core/voice, core/plugins, core/agents, core/config         │
├─────────────────────────────────────────────────────────────┤
│ Native / Platform Runtime                                   │
│ lib/native/* + native/android/*                             │
└─────────────────────────────────────────────────────────────┘
```

## 3. Composition root

`lib/injection_container.dart` is the composition root.
It wires together:

- persistence and preferences
- update/checking services
- sync manager and local sync server/client
- local runtime provider
- cloud data sources
- repositories and use cases
- voice engine
- plugin registry
- orchestrator and planner services

This file is critical because it makes the module boundaries visible in one place.

## 4. Core modules

### `core/orchestrator`
Defines the routing brain of the system.

Main responsibilities:

- input classification through `IntentAnalyzer`
- command routing through `ExecutionEngine`
- planning through `PlannerService`
- inference delegation through `InferenceService`

### `core/runtime/inference`
Defines runtime-neutral inference contracts and routing.

Main components:

- `InferenceRequest`
- `InferenceResponse`
- `RuntimeSession`
- `LocalRuntimeProvider`
- `CloudRuntimeProvider`
- `InferenceService`

This module is where local/cloud hybrid behavior is expressed.

### `core/memory`
Defines the memory abstraction and current context manager.

Main component:

- `ContextWindowManager`

This layer is responsible for keeping recent context usable across inference and orchestration flows.

### `core/sync`
Implements local-first CRDT synchronization primitives.

Main components:

- `SyncManager`
- `CrdtDocument`
- `CrdtRecord`
- `Hlc`
- local sync discovery/client/server services

This is the foundation for eventual peer sync and multi-device state propagation.

### `core/voice`
Defines a voice contract independent from the AI runtime.

Main components:

- `VoiceEngine`
- `VoiceInputService`
- `VoiceOutputService`
- `VoiceTextNormalizer`

### `core/plugins` and `core/agents`
Prepare the system for extensibility.

These modules allow the architecture to grow toward:

- plugin-delivered capabilities
- specialized agents
- tool orchestration
- future marketplace-like extensions

## 5. Feature modules

### `features/chat`
Conversation UX, chat persistence, and message flow.

### `features/projects`
Structured project memory persistence and editing.

### `features/local_ai`
Offline model lifecycle:

- download
- selection
- validation
- runtime-facing metadata

### `features/cloud_ai`
Provider-specific integrations behind a shared abstraction.

### `features/voice`
Sherpa-ONNX adapter and voice presentation layer.

### `features/document_intelligence`
Offline indexing and retrieval service with plugin integration.

### `features/coding_assistant`
Early specialized task/coding assistance primitives.

### Other supporting features
- onboarding
- settings
- multimodal

## 6. Native layer

The native layer exists to satisfy contracts defined in `core/`.

### Android runtime bridge
`native/android/` builds:

- `llama_bridge` for GGUF inference through `llama.cpp`
- `mlc_native_bridge` as a future-oriented MLC hook

### Platform bridges in `lib/native/`
- Android intent handling
- Bixby support
- runtime provider factories
- execution engine factories

The native layer should implement contracts, never define business rules for the whole application.

## 7. Data and control flow

### Conversational flow
```text
UI -> ChatBloc -> Orchestrator / InferenceService
   -> local runtime or cloud runtime
   -> response stream
   -> SQLite persistence
   -> UI update
```

### Project memory flow
```text
UI -> ProjectMemoryBloc -> repository -> local datasource -> SQLite
```

### Document indexing flow
```text
file -> LocalDocumentIndexService
     -> chunking
     -> hashed vector creation
     -> SQLite storage
     -> local similarity search
```

### Sync flow
```text
local write -> SyncManager.recordChange()
            -> SQLite sync_changes
            -> export/import changesets
            -> CRDT merge
```

### Voice flow
```text
voice input -> SherpaOnnxAdapter -> normalized text -> orchestration
orchestration output -> voice output service -> TTS
```

## 8. Import and dependency rules

### Allowed direction
- presentation -> domain/data/core
- features -> core
- native -> core
- composition root -> all modules

### Forbidden direction
- core -> features
- core -> native implementation details
- native -> features
- feature A directly owning feature B internals

The goal is to preserve dependency inversion and keep the core reusable.

## 9. Offline-first architecture in practice

This codebase is offline-first in architecture, not only in marketing.

Evidence in the repository:

- SQLite as local state foundation
- local sync change journal
- local document chunk/vector storage
- local runtime provider and GGUF path
- voice pipeline designed for offline ONNX use
- app-health services wired as mock/no-op defaults rather than mandatory telemetry infrastructure

## 10. Local vs cloud execution model

The architecture treats local and cloud execution as peers behind routing logic.

### Local path
- validated model required
- native runtime availability required
- best for privacy and offline continuity

### Cloud path
- selected provider required
- network required
- useful for capability extension and fallback

### Hybrid path
- `InferenceService` decides based on runtime mode, connectivity, model availability, and runtime errors

## 11. Vector memory model

The current vector memory implementation is intentionally lightweight.

Characteristics:

- embedded in app storage
- no external vector service required
- deterministic hashed embeddings
- cosine search over stored vectors
- suitable for offline retrieval and later replacement

This is an architectural stepping stone toward richer semantic memory.

## 12. Android constraints as an architectural concern

Android is not just a deployment target; it shapes the runtime architecture.

Important constraints:

- ABI support must remain explicit
- Flutter engine packaging must remain intact
- native `.so` packaging must be verified
- release signing must be correct
- local inference must use safe on-device model/runtime combinations

Because of this, Android packaging and CI validation are part of the system architecture, not merely build mechanics.

## 13. MLC evolution path

The codebase already includes MLC-oriented native hooks, but they are disabled by default.
This means:

- the architecture anticipates GPU/accelerated local runtimes
- the current production path is still the llama.cpp bridge
- future acceleration can be introduced without redesigning the full app

## 14. Future extensibility

The current module boundaries are suitable for:

- additional local runtimes
- new cloud providers
- better vector memory backends
- richer sync transports
- specialized agents and tools
- MobileIDE workflows
- Windows/Linux/macOS runtime adapters

## 15. Architectural north star

AI-Orchestrator should continue evolving as a **portable cognitive orchestration substrate**:

- local-first by default
- modular by design
- runtime-agnostic where possible
- explicit about platform constraints where necessary
