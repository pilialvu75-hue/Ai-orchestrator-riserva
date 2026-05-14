# AI-Orchestrator

AI-Orchestrator is a **modular offline-first cognitive orchestration platform** built with Flutter.
It is designed to run locally first, preserve project and document context on-device, and route work across local runtimes, cloud providers, plugins, tools, and future agent systems without collapsing into a generic chat app architecture.

## Vision

AI-Orchestrator is intended to evolve into a portable orchestration layer for:

- local reasoning and task execution
- project memory and context persistence
- offline document indexing and retrieval
- multimodal voice interaction
- hybrid local/cloud inference routing
- future multi-agent and MobileIDE workflows

The repository already contains the stable foundations for that direction:

- **orchestration core** in `lib/core/`
- **feature slices** in `lib/features/`
- **native Android runtime bridge** in `native/android/`
- **local-first sync primitives** in `lib/core/sync/`
- **offline document intelligence plugin** in `lib/features/document_intelligence/`

## Architectural Identity

AI-Orchestrator should be understood as:

> **A modular offline-first cognitive orchestration platform**

not as a thin wrapper around external LLM APIs.

Its architecture centers on these principles:

1. **Local-first execution** — SQLite, local memory, local document indexing, local sync state, and local runtime paths are primary.
2. **Hybrid inference** — the app can use local GGUF inference, cloud inference, or hybrid routing with fallback.
3. **Modular boundaries** — `core/` defines contracts, `features/` implements user-facing slices, `native/` fulfills platform contracts.
4. **Replaceable runtimes** — voice, inference, indexing, sync, and plugins can evolve independently.
5. **Privacy by design** — user context is stored locally; cloud is opt-in and provider-specific.

## System Overview

```text
Flutter UI / BLoC
        │
        ▼
Composition root (`lib/injection_container.dart`)
        │
        ├── Core orchestration
        │     ├── Orchestrator
        │     ├── InferenceService
        │     ├── ContextWindowManager
        │     ├── SyncManager
        │     └── PluginRegistry
        │
        ├── Feature modules
        │     ├── chat
        │     ├── projects
        │     ├── local_ai
        │     ├── cloud_ai
        │     ├── voice
        │     ├── document_intelligence
        │     └── coding_assistant
        │
        └── Native platform/runtime layer
              ├── Android FFI runtime (`libllama_bridge.so`)
              ├── Android intents / Bixby bridge
              └── future desktop/runtime adapters
```

## Core Capabilities

### 1. Task orchestration

`lib/core/orchestrator/orchestrator.dart` classifies input through `IntentAnalyzer` and routes it to:

- **ExecutionEngine** for command-style actions
- **PlannerService** for planning/coding decomposition
- **InferenceService** for conversational and reasoning flows

This keeps orchestration decisions separate from transport, UI, and provider logic.

### 2. Hybrid local/cloud inference

`lib/core/runtime/inference/inference_service.dart` implements the runtime routing layer.

Supported modes:

- **Local** — use a validated downloaded local model
- **Cloud** — use remote providers
- **Hybrid** — prefer one path, then fallback when appropriate

Current architecture includes:

- `AndroidFfiRuntimeProvider` for local GGUF inference through `libllama_bridge.so`
- `CloudRuntimeProvider` for remote provider access
- model validation before local runtime activation
- cloud fallback when the local runtime fails before producing output
- local fallback when cloud is unavailable and a valid local model exists

### 3. Offline project memory

`ContextWindowManager` and the project memory repositories preserve context locally in SQLite.

This includes:

- chat history
- current project context
- reusable project memory
- user preferences and runtime settings

The system is designed so context remains usable even with no network access.

### 4. Vector-like document memory

`LocalDocumentIndexService` provides an offline indexing pipeline:

- reads text and basic PDF payloads
- splits documents into overlapping chunks
- computes compact hashed vectors
- stores chunks and vector JSON in SQLite
- performs cosine similarity search locally

This is not yet a full external vector database. It is a lightweight embedded retrieval layer optimized for offline execution and future evolution.

### 5. Voice pipeline (ASR/TTS)

The voice subsystem is intentionally isolated from the main inference runtime.

Current voice path:

- `SherpaOnnxAdapter` implements `VoiceEngine`
- ASR/TTS are exposed over method and event channels
- `VoiceInputService`, `VoiceOutputService`, and `VoiceTextNormalizer` connect voice to the rest of the app

This means voice can evolve independently of the GGUF inference stack.

### 6. Local-first synchronization

`SyncManager` implements CRDT-style local-first sync primitives:

- local writes are recorded first
- changes are persisted in SQLite
- sync exports/imports operate on CRDT records
- last-write-wins conflict resolution is applied through the CRDT document model

This is the basis for future device-to-device or peer sync without requiring immediate cloud centralization.

## Offline-first Philosophy

AI-Orchestrator is designed so the application remains useful when disconnected.

What already works locally by architecture:

- SQLite-backed memory and chat storage
- document indexing and retrieval
- sync state and CRDT change tracking
- local model management
- Android on-device inference via FFI
- voice pipeline integration surface

Cloud services are treated as optional accelerators or capability extensions, not as the architectural center.

## Security and Privacy Model

The codebase favors a conservative local-only default posture.

### Local by default

- chat history is stored locally
- project memory is stored locally
- document chunks and vectors are stored locally
- sync records are stored locally
- preferences are stored locally

### Minimal remote assumptions

- cloud requests are only made when a cloud provider is selected
- provider API access is separated from the local inference layer
- mock/no-op app-health services avoid mandatory telemetry infrastructure in the current architecture

### Android build hardening

The Android build now emphasizes installability and packaging correctness over APK size optimization.
Important constraints include:

- ARM64-only target packaging for the Flutter/Android release path
- no native minification/shrinking in release
- explicit runtime checks for `libflutter.so` and `libapp.so`
- `GGML_OPENMP=OFF` to avoid shipping `libomp.so`, which has caused invalid-package failures on Samsung devices

## Platform Direction

### Current practical focus

- Android runtime validation
- Flutter mobile UI
- local-first orchestration foundations

### Ongoing or future direction

- Windows/Linux/macOS expansion through new runtime adapters
- broader offline assistant workflows
- deeper document intelligence
- multi-agent execution models
- MobileIDE-oriented orchestration, code assistance, and task automation

## Repository Map

```text
lib/
  core/                    Stable contracts, orchestration, sync, runtime, memory
  features/                Clean-architecture feature modules
  native/                  Platform-specific bridges selected at runtime
  injection_container.dart Composition root / dependency wiring
  main.dart                App entry point

native/
  android/                 llama.cpp bridge, MLC hook, Android CMake runtime

docs/
  GUIDA_IT.md              Guida generale in italiano
  MODULAR_ARCHITECTURE.md  Architettura modulare e confini dei moduli
  OFFLINE_RUNTIME.md       Runtime locale, cloud, memoria, indicizzazione, sync
  ANDROID_BUILD.md         Build Android, packaging, ABI, CI/CD
  TROUBLESHOOTING.md       Problemi comuni e recovery guide
  ROADMAP_EVOLUTIVA.md     Visione evolutiva di Core e MobileIDE
```

## Key Documents

- [Guida generale in italiano](docs/GUIDA_IT.md)
- [Modular architecture](docs/MODULAR_ARCHITECTURE.md)
- [Offline runtime](docs/OFFLINE_RUNTIME.md)
- [Android build guide](docs/ANDROID_BUILD.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Roadmap evolutiva](docs/ROADMAP_EVOLUTIVA.md)

## Local Development

### Prerequisites

- Flutter `>= 3.22.2`
- Dart `>= 3.4.0 < 4.0.0`
- Java 17
- Android SDK + NDK `26.1.10909125` for Android builds
- initialized `third_party/llama.cpp` submodule

### Typical commands

```bash
flutter pub get
flutter analyze --no-fatal-warnings --no-fatal-infos
flutter test
flutter build apk --release
```

## Android runtime note

The Android release pipeline currently prioritizes:

- valid installable APK structure
- correct Flutter engine packaging
- inclusion of native `.so` files
- signing and zip alignment verification

Do not optimize APK size first. Validate packaging correctness first.

## State of MLC integration

The native Android build contains an **MLC runtime integration surface** (`mlc_native_bridge` and `AI_ANDROID_ENABLE_MLC`) but the Android app currently builds with:

- `ANDROID_NATIVE_MLC_ENABLED = false`
- `-DAI_ANDROID_ENABLE_MLC=OFF`

So MLC is currently a prepared extension path, not the primary production runtime.

## Why this documentation exists

This repository must be understandable to:

- end users
- contributors
- future maintainers
- AI coding agents

The goal is not only to document what exists today, but also to make the long-term architecture legible and stable enough for continuous evolution.
