# native/

This directory contains platform-specific native (non-Dart) code for the AI Orchestrator.

## Subdirectories

| Directory    | Purpose |
|-------------|---------|
| `android/`  | Android-specific native code (JNI, C/C++ NDK modules) |
| `windows/`  | Windows-specific native code and DLL helpers |
| `macos/`    | macOS-specific native code and dylib helpers |
| `llama_cpp/`| Platform-agnostic llama.cpp integration layer (GGUF inference engine) |

> **Note:** The `llama_cpp/` submodule currently lives at `third_party/llama.cpp` for CMake
> build compatibility and will be migrated here once the CMake build logic is updated.
