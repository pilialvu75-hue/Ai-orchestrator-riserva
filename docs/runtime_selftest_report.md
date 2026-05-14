# Runtime Self-Test Report

## Implemented self-test

A hidden debug action now exists on the Settings runtime card:

- **Action:** long-press the runtime hero card
- **Entry point:** `SettingsPage` → `RuntimeSelfTestService`
- **Prompt used:** `Say hello`

## What the self-test verifies

1. A selected local model exists and has a concrete local path.
2. Runtime validation does not report `modelMissing`, `ffiMissing`, or `failed`.
3. A **real** chat request is executed through the existing pipeline.
4. At least one streamed partial response arrives.
5. Final assistant output is persisted in SQLite for session `__runtime_self_test__`.

## Execution path used by self-test

`SettingsPage` → `RuntimeSelfTestService.run()` → `ChatRepository.sendMessage()` → `Orchestrator.handleStream()` → `InferenceService.stream()` → `AndroidFfiRuntimeProvider` (Android) / `LocalRuntimeProvider` (desktop) → streamed response → SQLite persistence check.

## Runtime-state changes added for proof-of-life

Formal runtime states now include:

- `uninitialized`
- `modelMissing`
- `ffiMissing`
- `runtimeUnavailable`
- `loading`
- `ready`
- `inferencing`
- `failed`

Behavior change:

- The app no longer reports **ready** just because a model file exists.
- `validateRuntime()` now reports `runtimeUnavailable` until a real local inference has been proven.
- Successful streamed inference promotes the runtime back to `ready` with a verified message.

## Logging added for forensic proof

The pipeline now emits the required log markers:

- `[RUNTIME_PATH]`
- `[MODEL_LOAD]`
- `[FFI_INIT]`
- `[TOKEN_STREAM]`
- `[MODEL_EXECUTION]`
- `[FINAL_RESPONSE]`

## Current repository-level result

### Implemented

- Hidden self-test entry point
- Real prompt execution path
- Streamed-token requirement
- SQLite persistence verification
- Asset-backed model metadata registry for `assets/models/manifest.json`
- Tightened runtime state semantics

### Not yet proven in this sandbox

- Real Android-device inference with TinyLlama GGUF present on disk
- Successful packaging/loading of `libllama_bridge.so` inside an APK built from this checkout
- Presence of an actual bundled `assets/models/*.gguf` payload

## Blocking conditions that still prevent a full green proof here

1. No Flutter SDK is available in this execution environment, so `flutter analyze`, `flutter test`, and `flutter build apk` could not be run locally here.
2. No `.gguf` model file is committed in the repository, so the self-test will fail with `modelMissing` until a real model is downloaded or imported on-device.
3. No prebuilt Android `.so` artifacts are committed in `android/app/src/main/jniLibs/`; APK validation still depends on a successful native Android build.
4. `third_party/llama.cpp` is not populated in the current checkout until the submodule is initialized.

## Expected success criteria on device

After downloading/importing a valid TinyLlama GGUF and building an ARM64 APK with the native bridge present, the hidden self-test should pass only if:

- FFI loads successfully
- tokens stream back during `Say hello`
- an assistant reply is produced
- the final reply is written to SQLite
- the runtime state transitions to `ready` only after that proof
