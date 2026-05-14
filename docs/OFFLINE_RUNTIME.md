# Offline Runtime

This document explains how AI-Orchestrator executes work locally, how it falls back to cloud providers, and how memory, voice, indexing, and sync cooperate inside an offline-first runtime.

## 1. Runtime philosophy

The runtime is designed around a strict priority:

1. keep user state local
2. keep the application useful while offline
3. use cloud only when it adds value or is explicitly selected
4. make runtime substitution possible without rewriting the full app

## 2. Runtime building blocks

### Inference routing
`lib/core/runtime/inference/inference_service.dart`

Responsibilities:

- resolve current runtime mode
- inspect selected local model
- build local inference requests
- route between local/cloud runtimes
- perform fallback when a runtime fails
- stream partial output

### Local model lifecycle
`features/local_ai`

Responsibilities:

- download GGUF models
- persist model selection
- validate downloaded artifacts
- expose model metadata to runtime routing

### Android local runtime
`AndroidFfiRuntimeProvider`

Responsibilities:

- load `libllama_bridge.so`
- validate platform ABI
- validate model file size and supported IDs
- start generation
- poll native tokens
- handle cancellation
- surface runtime diagnostics

### Cloud runtime
`CloudRuntimeProvider`

Responsibilities:

- use configured providers through repository abstractions
- stream tokens when remote inference is selected
- expose fallback signals when cloud should yield to local

## 3. Local vs cloud inference behavior

### Local mode
Used when runtime mode is local and a valid local model exists.

Requirements:

- selected model is downloaded
- selected model has a valid path
- validation status is acceptable
- current runtime supports the model
- native library is packaged and loadable

Failure behavior:

- if local inference fails before generating output and cloud is allowed, the system can fall back to cloud

### Cloud mode
Used when runtime mode is explicitly cloud.

Requirements:

- network access
- configured provider
- usable credentials if required

Failure behavior:

- if cloud fails with a recoverable error and a local model exists, the system can fall back to local

### Hybrid mode
Used when the app should dynamically choose the best execution path.

Typical logic:

- if device is offline, prefer local
- if cloud is preferred for the request, use cloud first
- if no local model is valid, use cloud
- if cloud fails and local is available, recover locally

## 4. Local GGUF runtime on Android

Current local runtime path:

```text
InferenceService
  -> AndroidFfiRuntimeProvider
  -> dart:ffi
  -> libllama_bridge.so
  -> llama.cpp
  -> GGUF model file
```

Key traits:

- token streaming is polled from native code
- generation is bounded by timeouts and idle-poll safeguards
- only whitelisted model IDs are accepted for Android local runtime
- unsupported ABI or missing library is surfaced as a runtime state, not hidden

## 5. ONNX voice runtime

Voice is intentionally separate from GGUF text inference.

Current voice path:

```text
VoiceInputService / VoiceOutputService
  -> SherpaOnnxAdapter
  -> MethodChannel/EventChannel
  -> platform ASR/TTS implementation
```

Why this separation matters:

- ASR/TTS can evolve independently
- voice can remain offline
- main inference runtime does not need to own microphone/speaker concerns
- failures in voice do not invalidate the text runtime architecture

## 6. Vector memory and retrieval

`LocalDocumentIndexService` provides the current embedded retrieval system.

### Indexing pipeline
1. read file contents
2. extract raw text
3. split into overlapping chunks
4. produce compact hashed vectors
5. store chunk text + vector JSON in SQLite

### Query pipeline
1. normalize query
2. embed query with same lightweight embedding function
3. load candidate document chunks
4. score with cosine similarity
5. return top local matches

### What this means architecturally
The current implementation is:

- local-only
- deterministic
- lightweight
- replaceable later with stronger embeddings or a real vector backend

## 7. Project memory and context window

The runtime is not only about model execution. It also depends on structured local state.

### Context window
`ContextWindowManager` maintains recent working context for current sessions.

### Persistent context
SQLite stores:

- chat history
- project memory
- user preferences
- indexed document chunks
- sync changes

This lets the application reconstruct working state after app restarts or network loss.

## 8. Synchronization architecture

`SyncManager` implements local-first CRDT journaling.

### Properties
- writes are recorded locally first
- sync changes are stored in `sync_changes`
- exported changesets can be transmitted later
- imported changes merge with LWW rules
- the system remains useful without any active peer

This design avoids making remote infrastructure a prerequisite for data integrity.

## 9. Security and privacy posture

The offline runtime is also the privacy model.

### Local-only default posture
- memory remains on-device
- document retrieval remains on-device
- sync records remain on-device
- cloud is optional

### Cloud as explicit delegation
If the user selects a cloud provider, only the inference portion of the request leaves the local runtime boundary.
The rest of the app architecture remains local-first.

## 10. Android runtime constraints

The Android runtime has specific constraints that affect system behavior:

- valid ARM64 packaging is required
- Flutter engine libraries must remain packaged
- native `.so` files must load correctly
- runtime libraries must match the packaged ABI
- unsupported models must be rejected early

This is why packaging validation is part of runtime correctness.

## 11. MLC acceleration status

The repository already contains a future-facing MLC bridge on Android, but the active runtime is still the llama.cpp bridge.

Current state:

- MLC integration surface exists
- Android build flag keeps it disabled by default
- runtime documentation must treat MLC as prepared acceleration infrastructure, not as the currently active default engine

## 12. Evolution path

The offline runtime is intended to grow toward:

- stronger local retrieval and vector memory
- richer device-to-device sync
- more capable voice flows
- broader desktop runtime adapters
- MobileIDE-style orchestration and coding agents
- selective acceleration through MLC or other local backends
