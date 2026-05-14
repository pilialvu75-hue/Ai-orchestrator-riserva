# Critical Runtime Recovery + Architectural Re-Sync Report

## Phase 1 — Critical Runtime Stabilization

### Modified files
- `lib/core/runtime/inference/inference_service.dart`
- `lib/features/chat/data/repositories/chat_repository_impl.dart`
- `lib/core/orchestrator/state_engine/orchestrator_state_engine.dart`

### Root cause discovered
- The inference pipeline had no end-to-end request-level guardrails at orchestration level (duplicate prompt suppression, bounded retries, global stream hard-stop, guaranteed session cleanup).
- Repeated same-prompt triggers in a short window could re-enter the pipeline without a forensic trace that clearly distinguishes prompt creation/routing vs streaming.
- Context injection used full historical lines without dedupe caps, increasing risk of recursive context duplication.

### Stabilization changes
- Added forensic logs for: prompt creation, prompt routing, context injection, memory retrieval/model validation, model selection, streaming callbacks, response parsing, persistence, retry handlers, and async listener cleanup.
- Added hard-stop protections in `InferenceService`:
  - request timeout guard
  - idle stream timeout guard
  - max stream chunk guard
  - max retry count (`_maxRetryCount = 1`) with retryable-error filter
  - duplicate prompt hash protection (per session + rapid window)
- Added strict session cleanup in `finally` to prevent orphaned runtime sessions/listeners.
- Added context dedupe + capped context window in chat repository before prompt injection.

### Verification performed
- Static code-path verification of one request lifecycle:
  - prompt hash guard acquisition -> mode/model routing -> guarded stream -> final cleanup.
- Confirmed hard-stop guards always call cancellation token and terminate stream with deterministic error payload.
- Confirmed message persistence logs are emitted on user insert + assistant insert.

### Remaining blockers
- Cannot execute runtime integration tests in this environment because Flutter SDK is not available (`flutter: command not found`).
- Native runtime still depends on device-level validation for final loop-free behavior under real GGUF loads.

---

## Phase 2 — Architectural Recovery Forensics (Core vs current repository)

### Forensic comparison findings

#### Present and connected
- Local llama.cpp runtime bridge is present (`native/android/llama_bridge.cpp`, `AndroidFfiRuntimeProvider` path connected).
- TaskWeaver-inspired planner path is present (`core/planner/planner_service.dart`).
- Vector memory / offline indexing is present (`features/document_intelligence/data/services/local_document_index_service.dart`).
- Local-first sync modules are present (`core/sync/**`).

#### Present but disconnected / disabled
- MLC native bridge exists but disabled for Android builds:
  - `android/app/build.gradle` sets `ANDROID_NATIVE_MLC_ENABLED=false` and `-DAI_ANDROID_ENABLE_MLC=OFF`.
  - `native/android/CMakeLists.txt` keeps MLC behind compile-time flag.
- GPU acceleration backend channel exists (`MlcNativeBridge.kt`) but reports fallback/non-MLC when flag is off.

#### Missing/blocked runtime assets or bindings
- No prepackaged native `.so` artifacts under `android/app/src/main/**`; runtime depends on build-time native output only.
- Sherpa voice JNI wiring is not implemented in Android entrypoint:
  - `MainActivity.kt` returns `SHERPA_NOT_IMPLEMENTED` for `startAsr/stopAsr/speakTts/stopTts`.
  - ASR event stream handler is placeholder-only.

### Verification performed
- Source-level forensics across Android Gradle/CMake/Kotlin bridge and runtime/provider wiring.
- Confirmed ABI targeting and native flag state from current build files.

### Remaining blockers
- Without a reference checkout of original `AI-Orchestrator-Core`, module-by-module binary delta cannot be fully quantified in this workspace.
- APK-size delta root-cause requires artifact-level comparison (old vs new APK contents) outside current checkout.

---

## Phase 3 — Offline-First Restoration Status

### Modified files
- `lib/features/chat/presentation/pages/chat_page.dart` (runtime indicator surfacing for operational visibility)

### Current status
- Local runtime, model loader, offline document indexing, vector-like retrieval, and local sync paths remain present.
- Cloud provider remains optional (fallback architecture preserved).
- Voice pipeline contract exists, but Android native execution path is not fully wired (see blocker below).

### Verification performed
- Confirmed local-first routing and cloud fallback behavior in `InferenceService`.
- Confirmed local runtime diagnostics monitor path remains active and now surfaced in UI with additional runtime indicators.

### Remaining blockers
- Sherpa ASR/TTS native method handlers are still non-operational in Android (`SHERPA_NOT_IMPLEMENTED` path), so microphone -> offline Sherpa transcription is not fully restored.

---

## Phase 4 — UI/UX Re-Sync

### Modified files
- `lib/features/chat/presentation/pages/chat_page.dart`

### Implemented
- Runtime-aware status indicators now surfaced in chat overlay for:
  - Local runtime active
  - Voice engine active
  - Offline mode active
  - GPU acceleration active + backend label
- Existing model category split was already present in `features/local_ai/presentation/pages/models_page.dart`:
  - Mobile Models
  - Desktop Models

### Root cause discovered
- Runtime capability visibility was fragmented; users could not quickly tell if voice/offline/GPU pathways were actually live.

### Verification performed
- Static verification of indicator data sources:
  - local runtime monitor (`LocalRuntimeDiagnosticsService`)
  - voice engine inspect (`VoiceEngine.inspect`)
  - runtime mode (`AiRuntimeSettingsService`)
  - GPU backend capability (`com.aiorchestrator/mlc_native` method channel)

### Remaining blockers
- Indicator can report Sherpa availability, but Android native voice handlers still need full ASR/TTS implementation to satisfy real microphone-to-transcription execution.

---

## Phase 5 — Future Merge Preparation

### Prepared in this pass
- Request lifecycle logging and guardrails are now concentrated in core orchestration/runtime layers, improving future merge traceability.
- Recovery findings are documented in a single forensic report for migration planning.

### Remaining blockers before reintegration into Core
- Implement full Sherpa Android runtime wiring (`startAsr`, stream events, `speakTts`).
- Validate runtime fixes on-device and capture loop-free inference traces.
- Produce artifact-level old/new APK contents diff against original Core branch.
