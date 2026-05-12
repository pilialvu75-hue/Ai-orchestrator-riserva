# Local Runtime on Android — Implementation Guide

This document describes the end-to-end architecture of the on-device AI inference
pipeline that runs GGUF models on Android via `libllama_bridge.so`.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Native Bridge (llama_bridge)](#native-bridge-llama_bridge)
3. [CMake Build Configuration](#cmake-build-configuration)
4. [Dart FFI Bridge](#dart-ffi-bridge)
5. [GGUF Model Loading](#gguf-model-loading)
6. [APK Packaging](#apk-packaging)
7. [Building Locally](#building-locally)
8. [CI/CD Integration](#cicd-integration)
9. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Flutter UI (Dart)
      │
      ▼
AndroidFfiRuntimeProvider          (lib/core/runtime/inference/)
      │  dart:ffi  +  package:ffi
      ▼
libllama_bridge.so                 (android/app/src/main/jniLibs/arm64-v8a/)
      │  C API  llb_*
      ▼
llama.cpp (static)                 (third_party/llama.cpp)
      │
      ▼
GGUF model file                    (~/.../models/<model>.gguf on device)
```

For multimodal voice, the app now also reserves a separate Sherpa-ONNX bridge
surface (method/event channels) so ASR/TTS remain decoupled from this llama.cpp
inference stack:

```
Flutter Voice Layer (features/voice/)
      │
      ▼
SherpaOnnxVoiceAdapter (method/event channel)
      │
      ▼
Android Sherpa-ONNX native module (offline ONNX ASR/TTS)
```

The bridge is a **thin C shim** compiled from `native/android/llama_bridge.cpp`.
It presents a simple polling API to Dart, hiding all llama.cpp internals behind
opaque global state so that the Dart FFI bindings stay minimal and type-safe.

---

## Native Bridge (llama_bridge)

### Files

| File | Purpose |
|------|---------|
| `native/android/llama_bridge.h`   | Public C API declaration |
| `native/android/llama_bridge.cpp` | Implementation |
| `native/android/CMakeLists.txt`   | CMake build script |

### C API

```c
// Load a GGUF model.  Must be called before starting generation.
int32_t llb_load_model(const char* model_path, int32_t n_ctx, int32_t n_threads);

// Start async token generation in a background POSIX thread.
int32_t llb_start_gen(const char* prompt, int32_t max_tokens, float temperature);

// Non-blocking poll: returns 1 (token in buf), 2 (done), 0 (not ready),
//                           -1 (error), or -99 (cancelled).
int32_t llb_poll_token(char* buf, int32_t buf_size);

// Signal the background thread to stop.
void llb_cancel(void);

// Free the loaded model and release all native memory.
void llb_free_model(void);

// Return last error string (valid until the next bridge call).
const char* llb_last_error(void);

// 1 if a model is currently loaded, 0 otherwise.
int32_t llb_is_loaded(void);
```

### Threading model

`llb_start_gen` spawns a POSIX `std::thread` that runs the full
tokenise → prefill → decode loop.  Generated token pieces are pushed into a
mutex-guarded ring buffer (capacity 256).  The Dart event loop drains the ring
via `llb_poll_token()` without blocking the UI thread.  `llb_cancel()` is
atomic and safe to call from any thread.

---

## CMake Build Configuration

`native/android/CMakeLists.txt` compiles `libllama_bridge.so` as follows:

1. Adds `third_party/llama.cpp` as a static-library sub-project
   (`BUILD_SHARED_LIBS=OFF`, tests/examples disabled).
2. Compiles `llama_bridge.cpp` into a shared library named `llama_bridge`.
3. Links against the static `llama` + `ggml` targets and the Android NDK
   libraries `log` and `android`.
4. Applies `-O3 -fno-finite-math-only -DNDEBUG` optimisation flags.

`android/app/build.gradle` wires CMake into the AGP build:

```groovy
externalNativeBuild {
    cmake {
        path "../../native/android/CMakeLists.txt"
        version "3.22.1"
    }
}
defaultConfig {
    externalNativeBuild {
        cmake {
            cppFlags "-std=c++17 -O3 -fno-finite-math-only -DNDEBUG"
            abiFilters "arm64-v8a"
        }
    }
}
```

Running `flutter build apk` (or `flutter build apk --release`) automatically
invokes CMake → NDK → clang++ and places `libllama_bridge.so` into the APK.

---

## Dart FFI Bridge

`lib/core/runtime/inference/android_ffi_runtime_provider.dart` implements
`LocalRuntimeProvider` using `dart:ffi` + `package:ffi`.

### Library loading

```dart
DynamicLibrary.open('libllama_bridge.so')
```

Tried first; falls back to `libllama.so` (direct llama.cpp build) if absent.

### FFI type mappings

| C type | Dart native type | Dart value type |
|--------|-----------------|-----------------|
| `int32_t` | `Int32` | `int` |
| `float` | `Float` | `double` |
| `const char*` | `Pointer<Utf8>` | `String` (via `toNativeUtf8`) |
| `char*` (out) | `Pointer<Uint8>` cast to `Pointer<Utf8>` | read with `toDartString()` |
| `void` | `Void` | — |

### Output buffer allocation (ffi 2.x compatible)

```dart
final tokenBufRaw = calloc<Uint8>(_tokenBufSize);  // allocate as Uint8
final tokenBuf = tokenBufRaw.cast<Utf8>();          // cast for API call
// …
calloc.free(tokenBufRaw);                           // free the Uint8 pointer
```

`calloc<Utf8>(size)` is invalid in `package:ffi` 2.x and will throw at
runtime; always allocate as `Uint8` and cast.

### Isolate-based model loading

`llb_load_model` can block for several seconds on large GGUF files.  The
provider offloads it to a background `Isolate` (via `Isolate.run`) so the
Flutter UI stays responsive.  Because `DynamicLibrary` handles are not
isolate-transferable, the library is re-opened fresh inside the isolate.

### Polling loop

```dart
while (true) {
  final status = bindings.pollToken(tokenBuf);
  if (status == 1)   { /* emit token */ }
  else if (status == 2)   { /* EOS – done */ break; }
  else if (status == -99) { /* cancelled */ break; }
  else if (status == -1)  { /* error */ break; }
  else /* status == 0 */  { await Future.delayed(Duration(milliseconds: 8)); }
}
```

The 8 ms yield keeps CPU usage low while the native thread hasn't produced
a token yet.

---

## GGUF Model Loading

Models are downloaded to the app's `getApplicationDocumentsDirectory()` path
under a `models/` sub-directory by `ModelDownloadService` (Dio, resumable,
GGUF-header validated).

`llb_load_model` receives the absolute path and:
1. Calls `llama_backend_init()`.
2. Sets `n_gpu_layers = 0` (CPU-only; safe on all Android devices).
3. Creates a `llama_model*` and a `llama_context*` with the given context size
   and thread count.

---

## APK Packaging

`libllama_bridge.so` is placed in the APK under:

```
lib/arm64-v8a/libllama_bridge.so
```

AGP handles this automatically when `externalNativeBuild` is configured.
At runtime `DynamicLibrary.open('libllama_bridge.so')` loads from the APK's
extracted native library directory (set by the Android linker).

The static llama.cpp and ggml objects are linked directly into
`libllama_bridge.so`, so no additional `.so` files need to be packaged.

---

## Building Locally

### Prerequisites

```bash
# 1. Initialise the llama.cpp submodule
git submodule update --init --recursive

# 2. Ensure Android NDK 27.0.12077973 is installed
# (Android Studio → SDK Manager → SDK Tools → NDK)

# 3. Build the APK (CMake/NDK build is automatic)
flutter build apk --debug
```

### Manual CMake build (optional)

```bash
cmake \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DCMAKE_BUILD_TYPE=Release \
  -S native/android \
  -B build/android/arm64-v8a

cmake --build build/android/arm64-v8a --target llama_bridge

# Copy to jniLibs
cp build/android/arm64-v8a/libllama_bridge.so \
   android/app/src/main/jniLibs/arm64-v8a/
```

---

## CI/CD Integration

Both GitHub Actions workflows (`.github/workflows/main.yml` and
`.github/workflows/build.yml`) include:

1. **`actions/checkout@v4` with `submodules: recursive`** — initialises
   `third_party/llama.cpp`.
2. **`nttld/setup-ndk@v1` with `ndk-version: r27`** — installs the NDK on the
   ubuntu-latest runner.
3. **`flutter build apk`** — triggers Gradle → CMake → NDK compilation of
   `libllama_bridge.so` and bundles it into the APK.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `libllama_bridge.so not found` at runtime | Library missing from APK | Ensure `externalNativeBuild` is in `build.gradle` and llama.cpp submodule is initialised |
| `CMake Error: llama.cpp submodule not found` | Submodule not cloned | `git submodule update --init --recursive` |
| Crash on `llb_load_model` | OOM / bad model path | Verify path with `llb_is_loaded()` return value; check logcat |
| Tokenisation returns -1 | Context window too small | Increase `n_ctx` in `_LlamaBridgeBindings._defaultNCtx` |
| UI freezes during model load | Model load on main isolate | Already handled via `Isolate.run` in `AndroidFfiRuntimeProvider` |
| `calloc<Utf8>` crash (ffi 2.x) | Invalid allocation type | Use `calloc<Uint8>` and cast to `Pointer<Utf8>` |
