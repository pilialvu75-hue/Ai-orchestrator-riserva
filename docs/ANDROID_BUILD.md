# Android Build Guide

This document describes the Android build pipeline, runtime packaging expectations, and recovery rules for AI-Orchestrator.

## 1. Build objective

The Android build is not only expected to compile. It must produce a **valid, installable APK** with:

- correct Flutter engine packaging
- correct native `.so` inclusion
- valid signing
- correct ABI targeting
- zip-aligned final artifact

For this repository, installability is more important than size optimization.

## 2. Current Android toolchain

Verified from the repository:

- **Android Gradle Plugin:** 8.5.2
- **Gradle:** 8.7
- **Kotlin Android plugin:** 2.1.21
- **compileSdk / targetSdk:** 34
- **minSdk:** 24
- **NDK:** 26.1.10909125
- **Java target:** 17

## 3. ABI strategy

The current Android release path targets:

- `arm64-v8a`
- Flutter target platform `android-arm64`

This matches the current guarded Android packaging strategy and avoids unsupported ABI combinations.

The native Android CMake runtime also hard-fails unsupported ABIs.

## 4. Build files involved

### `android/app/build.gradle`
Defines:

- app namespace and SDK levels
- release signing behavior
- external native build configuration
- Android runtime compile flags
- release minification/shrinking policy

### `native/android/CMakeLists.txt`
Defines:

- `llama_bridge` shared library
- `mlc_native_bridge` shared library
- llama.cpp integration
- ABI guardrails
- compiler and link settings

### `.github/workflows/build.yml`
Defines CI validation, artifact collection, signing checks, forensics, and release publishing.

## 5. Release packaging rules

The release build currently follows these rules:

- `minifyEnabled false`
- `shrinkResources false`
- no aggressive packaging overrides for native libs
- Flutter default packaging behavior must remain intact
- native `.so` verification is performed after build

These settings exist to preserve runtime validity first.

## 6. Flutter engine packaging expectations

A valid release APK must contain at least:

- `libflutter.so`
- `libapp.so`
- `lib/arm64-v8a/`

If these are missing, the APK may compile but still be invalid or non-installable.

This is why CI now includes native library verification after build.

## 7. Native runtime libraries

The Android build can include native libraries from multiple origins:

### Flutter runtime libraries
Provided by Flutter packaging:

- `libflutter.so`
- `libapp.so`

### App native runtime libraries
Produced by native build configuration:

- `libllama_bridge.so`
- `libmlc_native_bridge.so` when built

### Why this matters
A build can appear successful while still producing an invalid APK if Flutter engine libraries are filtered out or if incompatible native libraries are packaged.

## 8. Release signing model

The release build expects runtime-provided signing material.

### Required secrets
- `ANDROID_KEYSTORE_BASE64`
- `KEYSTORE_PASSWORD`
- `KEY_ALIAS`
- `KEY_PASSWORD`

### Behavior
- CI decodes the keystore at runtime into a temporary directory
- release signing is used when credentials are valid
- debug-signing fallback can be used only for temporary installability validation

A missing or malformed keystore does not mean the build system is broken; it means the signing path must be repaired.

## 9. Standard local build flow

### Prerequisites
- Flutter SDK installed
- Android SDK installed
- NDK `26.1.10909125` installed
- `third_party/llama.cpp` submodule initialized
- `android/local.properties` pointing to Flutter and Android SDK paths

### Commands

```bash
flutter pub get
flutter analyze --no-fatal-warnings --no-fatal-infos
flutter test
flutter build apk --release
```

Use the standard Flutter command first. Avoid introducing split-per-ABI or custom normalization logic during recovery work.

## 10. CI/CD build flow

The GitHub Actions workflow performs, in broad terms:

1. checkout with submodules
2. Java and Flutter setup
3. Android SDK/NDK installation
4. signing validation and temporary keystore handling
5. `flutter pub get`
6. `flutter analyze`
7. `flutter test`
8. release APK build
9. release AAB build
10. output discovery and forensic checks
11. signature, zipalign, and archive validation
12. artifact upload and GitHub release publishing

## 11. APK validity checks

The Android pipeline should always be able to answer these questions:

### Is the APK present?
Check the resolved release path in `build/app/outputs/flutter-apk/`.

### Is the APK structurally valid?
Use:

```bash
unzip -t build/app/outputs/flutter-apk/app-release.apk
```

### Is it correctly aligned and signed?
Use:

```bash
apksigner verify --verbose --print-certs app-release.apk
zipalign -c -v 4 app-release.apk
```

### Are required native libraries present?
Use:

```bash
unzip -l build/app/outputs/flutter-apk/app-release.apk | grep '\.so'
```

### Is package metadata readable?
Use:

```bash
aapt dump badging app-release.apk
```

## 12. Common failure classes

### Invalid package / app not installed
Usually caused by one of these:

- missing `libflutter.so`
- missing `libapp.so`
- bad signing
- incompatible or missing native `.so`
- ABI mismatch
- invalid packaging overrides

### ABI conflicts
Often caused by:

- forcing unsupported ABIs through Gradle or Flutter flags
- CMake being asked to build for an ABI it rejects
- packaging libraries for ABIs that the runtime does not support consistently

### Kotlin / Gradle compatibility
Usually caused by plugin version drift or incompatible transitive plugin metadata.

### Native runtime inclusion failures
Usually caused by:

- missing submodule
- CMake misconfiguration
- aggressive packaging exclusions
- ABI mismatch between compiled native output and packaged APK

## 13. Build guardrails for this repository

### OpenMP must stay disabled for Android
`GGML_OPENMP=OFF` is required.

Reason:
- bundling `libomp.so` has already been associated in this project with invalid-package or install failures on Samsung devices, so it is treated as unsafe for the Android release packaging path

### Do not strip Flutter engine libs through custom packaging
If `libflutter.so` or `libapp.so` disappear, the build is invalid regardless of successful compilation.

### Avoid premature APK size optimization
Do not reintroduce native packaging optimization until installability is verified.

## 14. Recovery checklist

When Android release artifacts become invalid, apply this order:

1. build with the standard Flutter release command
2. inspect APK contents for `.so` files
3. verify `libflutter.so` and `libapp.so`
4. verify `lib/arm64-v8a/` exists
5. verify signing
6. verify zipalign
7. check for custom ABI or packaging overrides
8. check for incompatible native libraries such as `libomp.so`
9. run `aapt dump badging`
10. only after validity is restored, revisit optimization

## 15. Role of CI diagnostics

The workflow publishes logs that should be treated as part of the Android build architecture:

- build logs
- release output discovery logs
- APK forensic logs
- signature and zipalign logs
- archive content logs
- native library verification logs

These diagnostics are essential for future maintainers and AI agents because Android build failures are often packaging failures, not compile failures.
