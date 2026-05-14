# Runtime Asset Forensics

## Repository-wide binary scan

Scanned for `.gguf`, `.bin`, `.onnx`, `tokenizer*`, native `.so`, APK runtime assets, download manifests, Gradle packaging rules, CMake targets, and CI references.

### Direct binary artifact findings

- `.gguf`: none committed in the repository
- `.bin`: none committed in the repository
- `.onnx`: none committed in the repository
- `tokenizer*`: none committed in the repository
- `.so`: none committed in the repository
- `android/app/src/main/jniLibs/`: missing
- `android/app/src/main/assets/`: missing

## Runtime artifact inventory

| Path | Size (bytes) | Purpose | Referenced by Flutter | Copied into APK | Loadable at runtime |
|---|---:|---|---|---|---|
| `assets/models/manifest.json` | 465 | Flutter asset manifest for curated local-model metadata; keyed by model ID and currently lists TinyLlama 1.1B Chat metadata only. | Yes (`lib/features/local_ai/data/services/bundled_model_registry_service.dart`, `pubspec.yaml`) | Yes, as Flutter asset metadata. | Yes, for metadata only; no GGUF payload is bundled beside it. |
| `models/manifest.json` | 47 | Remote version-manifest payload used by update checks. | Yes (`AppConstants.modelVersionManifestUrl`, `ModelDownloadService.checkForUpdates`) | No | No; this is repository/HTTP metadata only. |
| `pubspec.yaml` | 1041 | Declares `assets/models/` for Flutter packaging. | Yes | Yes | Indirectly; enables loading `assets/models/manifest.json`. |
| `lib/core/config/app/app_constants.dart` | 8024 | Fallback built-in catalog and download URL registry; now reduced to the TinyLlama verification model. | Yes | Compiled into Dart snapshot | Yes, as app logic. |
| `lib/features/local_ai/data/services/bundled_model_registry_service.dart` | 1145 | Loads `assets/models/manifest.json` and falls back to `AppConstants.availableModels`. | Yes | Compiled into Dart snapshot | Yes. |
| `lib/features/local_ai/data/services/model_download_service.dart` | 27112 | Discovers model metadata, validates GGUF files, downloads/imports models, and persists selected model ID. | Yes | Compiled into Dart snapshot | Yes; requires a real GGUF on device storage. |
| `lib/core/runtime/inference/runtime_self_test_service.dart` | 4234 | Hidden proof-of-life self-test runner that executes a real prompt and verifies token streaming plus SQLite persistence. | Yes | Compiled into Dart snapshot | Yes, but only when a valid model and runtime are available. |
| `lib/native/runtime/local_runtime_provider_factory.dart` | 1023 | Selects `AndroidFfiRuntimeProvider` on Android and desktop CLI provider elsewhere. | Yes | Compiled into Dart snapshot | Yes. |
| `lib/core/runtime/inference/inference_service.dart` | 17640 | Active runtime router used by the chat pipeline; now emits `[RUNTIME_PATH]`, `[MODEL_LOAD]`, `[TOKEN_STREAM]`, and `[FINAL_RESPONSE]` diagnostics. | Yes | Compiled into Dart snapshot | Yes. |
| `lib/core/runtime/inference/local_runtime_provider.dart` | 10946 | Desktop CLI provider and shared runtime-proof state logic. | Yes | Compiled into Dart snapshot | Yes on desktop; not used for Android execution. |
| `lib/core/runtime/inference/android_ffi_runtime_provider.dart` | 34441 | Active Android runtime provider; loads `libllama_bridge.so`, executes local inference, streams tokens, and updates runtime states. | Yes | Compiled into Dart snapshot | Yes if the native bridge and a valid GGUF exist on-device. |
| `lib/core/runtime/inference/ffi/llama_ffi_loader.dart` | 1627 | Opens `libllama_bridge.so` and validates ABI support. | Yes | Compiled into Dart snapshot | Yes if the shared library is present in the APK/runtime linker path. |
| `native/android/CMakeLists.txt` | 5402 | Defines Android native builds for `llama_bridge` and `mlc_native_bridge`; expects `third_party/llama.cpp`. | No | Indirectly, via Gradle externalNativeBuild output | Build-time only. |
| `native/android/llama_bridge.cpp` | 32206 | Native llama.cpp bridge that performs real token generation for Android FFI. | No | Build output only | Not directly; produces `libllama_bridge.so` when built. |
| `native/android/llama_bridge.h` | 3465 | C ABI contract exposed to Dart FFI (`llb_load_model`, `llb_start_gen`, `llb_poll_token`, etc.). | No | Build output only | Not directly; header only. |
| `native/android/mlc_jni_bridge.cpp` | 2394 | Optional JNI diagnostics bridge for MLC backend availability and cache sizing. | No | Build output only | Not directly; produces `libmlc_native_bridge.so` when built. |
| `android/app/build.gradle` | 6316 | Enables `externalNativeBuild`, ARM64-only packaging, and disables MLC + OpenMP. | No | Indirectly controls APK contents | Build-time only. |
| `android/app/src/main/kotlin/com/aiorchestrator/MlcNativeBridge.kt` | 1446 | Kotlin JNI wrapper that attempts to load `mlc_native_bridge`. | No | Compiled into APK classes.dex | Yes if `libmlc_native_bridge.so` is packaged. |
| `.github/workflows/build.yml` | 19011 | CI build path; initializes llama.cpp submodule, runs Flutter validation, builds release APK/AAB, and verifies ARM64 native-library presence. | No | No | CI-only. |
| `third_party/llama.cpp` | 0 | Git submodule mount point for llama.cpp native sources. Current clone does not contain populated submodule contents. | No | No until submodule is initialized and built | No in current checkout. |

## Packaging/loadability conclusions

### Flutter-packaged assets

- `assets/models/manifest.json` **will** be packaged into the Flutter asset bundle.
- No actual `.gguf` model file exists under `assets/models/`, so the bundled asset architecture is present but **not sufficient for local inference by itself**.

### Native Android libraries

- `libllama_bridge.so` is **not committed** under `android/app/src/main/jniLibs/`.
- `libmlc_native_bridge.so` is **not committed** under `android/app/src/main/jniLibs/`.
- The intended packaging path is **build-time generation** through `android/app/build.gradle` + `native/android/CMakeLists.txt`.
- Runtime loadability on Android therefore depends on:
  1. `third_party/llama.cpp` submodule being initialized,
  2. Gradle/CMake successfully producing ARM64 `.so` outputs,
  3. those outputs being packaged into the APK.

### Model loadability

- The app can discover TinyLlama metadata from the Flutter asset manifest.
- The app can validate and execute a **real GGUF only if** the file has been downloaded/imported into device storage.
- There is currently **no committed GGUF payload** in the repository, so local inference still depends on runtime download/import.

## Active Android inference path

`OrchestratorStateEngine` → `ChatRepositoryImpl` → `Orchestrator.handleStream()` → `InferenceService.stream()` → `createLocalRuntimeProvider()` → `AndroidFfiRuntimeProvider` → `libllama_bridge.so` / `native/android/llama_bridge.cpp` → token stream → `chat_history` SQLite persistence.

## Current blockers discovered by forensics

1. No real `.gguf` model file is committed in the repository.
2. No prebuilt `libllama_bridge.so` or `libmlc_native_bridge.so` is committed in `android/app/src/main/jniLibs/`.
3. `third_party/llama.cpp` is an empty submodule mount point in the current checkout until `git submodule update --init --recursive` runs.
4. The new Flutter asset registry contains metadata only; it does not bundle a GGUF payload yet.
5. CI verifies generic ARM64 native-library presence, but this checkout cannot prove APK packaging without a successful Android build.
