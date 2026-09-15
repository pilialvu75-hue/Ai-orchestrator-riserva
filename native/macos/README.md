# macOS native/runtime layer

The macOS application shell is built with Flutter/Xcode. Local GGUF inference on desktop uses the process-based `LocalRuntimeProvider`, not the Android JNI/FFI bridge.

## Runtime direction

The production macOS bundle will carry its own `llama-cli` helper built from the repository `third_party/llama.cpp` submodule. The helper must be resolved from inside the `.app` bundle before falling back to `AI_ORCHESTRATOR_LLAMA_BIN` or the developer PATH.

Apple Silicon builds should use llama.cpp's Metal backend. The helper is deliberately kept separate from the Android bridge so macOS work cannot destabilize Android inference.

## Distribution requirements

Before the macOS branch is considered production-ready:

- bundle and validate the `llama-cli` helper;
- keep Cloud/BYOK functional through the macOS Keychain;
- preserve microphone and user-selected file permissions;
- sign the application and embedded executable together;
- notarize the distributable package;
- validate update metadata before enabling automatic updates.

The CI foundation may publish an unsigned ZIP for engineering tests, but that artifact is not the final end-user distribution format.
