# native/llama_cpp/

llama.cpp integration layer for on-device GGUF model inference.

This directory is the designated home for the [llama.cpp](https://github.com/ggerganov/llama.cpp)
submodule, which powers local AI inference across all supported platforms.

## Current Status

The llama.cpp submodule is currently registered at `third_party/llama.cpp` for CMake build
compatibility. Migration to this path is pending an update to the CMake build logic.

## Planned Contents

- `llama.cpp` submodule (GGUF C/C++ inference engine)
- Platform-specific CMake configuration wrappers
- Binding headers for Dart FFI (`llama_cpp_dart`)
