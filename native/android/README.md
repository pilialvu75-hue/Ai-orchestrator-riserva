# native/android/

Android-specific native code for AI Orchestrator.

This directory is the designated location for:
- JNI bridge code for on-device inference
- Android NDK C/C++ modules
- Android-specific hardware acceleration helpers

## Current native integration

- `llama_bridge.cpp`: existing FFI bridge used by Dart (`libllama_bridge.so`)
- `mlc_jni_bridge.cpp`: JNI runtime hook for native Android MLC availability and diagnostics
- `CMakeLists.txt`: builds both bridges and enables conditional MLC integration

When `third_party/mlc-llm` is present, the JNI bridge is compiled with
`AI_ENABLE_MLC_RUNTIME=1`. If not present, the bridge remains buildable and
reports fallback mode so offline local runtime can continue using the existing
llama bridge.
