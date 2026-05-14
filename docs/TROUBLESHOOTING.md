# Troubleshooting

This guide focuses on operational recovery for AI-Orchestrator, with special attention to Android packaging and offline runtime behavior.

## 1. Android: APK installs fail with “invalid package” or “app not installed”

### Likely causes
- missing `libflutter.so`
- missing `libapp.so`
- missing `lib/arm64-v8a/`
- bad release signing
- incompatible native library packaged into the APK
- ABI mismatch

### What to check

```bash
unzip -l build/app/outputs/flutter-apk/app-release.apk | grep '\.so'
```

Confirm presence of:

- `libflutter.so`
- `libapp.so`
- `lib/arm64-v8a/`

Then run:

```bash
aapt dump badging build/app/outputs/flutter-apk/app-release.apk
apksigner verify --verbose --print-certs build/app/outputs/flutter-apk/app-release.apk
zipalign -c -v 4 build/app/outputs/flutter-apk/app-release.apk
```

### Recovery
- remove custom ABI filtering that interferes with Flutter packaging
- remove custom packaging exclusions affecting `.so` files
- keep release minify/shrink disabled
- rebuild with `flutter build apk --release`

## 2. Android: APK size suddenly drops far below normal

### Symptom
A release APK that was previously around 50 MB becomes dramatically smaller.

### Meaning
This usually indicates that Flutter runtime or native libraries were excluded from packaging.

### Recovery
- inspect `.so` contents immediately
- verify Flutter engine libs are still present
- check for packaging changes in `build.gradle`
- check for ABI-specific filtering or exclusions in CI or Gradle properties

## 3. Android: missing `libflutter.so` or `libapp.so`

### Why it happens
- packaging overrides
- hardcoded ABI filters interfering with Flutter's normal packaging behavior
- invalid Gradle properties affecting ABI injection
- release packaging experiments

### Recovery
- restore Flutter default APK packaging behavior
- avoid custom `packagingOptions` for `.so` handling unless strictly necessary
- use the standard Flutter release build command first

## 4. Android: native `.so` libraries are missing

### Examples
- `libllama_bridge.so` missing
- `libmlc_native_bridge.so` missing
- `libflutter.so` missing

### Check
```bash
find build -name '*.so'
unzip -l build/app/outputs/flutter-apk/app-release.apk | grep '\.so'
```

### Recovery
- verify `externalNativeBuild` is configured
- verify `third_party/llama.cpp` submodule exists
- verify CMake completed for the intended ABI
- verify packaging did not exclude the library

## 5. Android: ABI conflicts

### Symptoms
- CMake configure failure
- app installs on one device but not another
- runtime cannot load library for current ABI

### Root causes
- requesting unsupported ABIs
- mismatch between Flutter target platforms and native build outputs
- packaging mixed ABI sets inconsistently

### Recovery
- align Flutter target platforms with supported native ABIs
- keep the repository's explicit Android ABI strategy
- do not add extra ABI targets until native support is ready end-to-end

## 6. Android: `libomp.so` causes install failures

### Symptom
Samsung or similar devices reject the APK even though the build succeeds.

### Cause
`libomp.so` is not part of the expected Android system runtime for this app packaging path. In this repository it has already been associated with invalid-package or install failures on Samsung devices during APK distribution tests.

### Recovery
Ensure Android native build keeps:

- `GGML_OPENMP=OFF`

Do not re-enable it during packaging recovery work.

## 7. Android: Gradle / Kotlin compatibility failures

### Symptoms
- plugin resolution failures
- Kotlin metadata mismatch
- AGP task failures after dependency updates

### Recovery
- verify AGP, Gradle, and Kotlin plugin versions in the repository
- avoid uncoordinated plugin upgrades
- check whether a Flutter plugin has raised its Kotlin toolchain requirements
- review `pubspec.yaml` constraints before changing Android plugin dependencies

## 8. Android: signing / keystore failures

### Symptoms
- release build fails before packaging
- release APK exists but is not accepted as validly signed
- CI falls back to debug signing

### Recovery
Verify the following secrets are present and valid:

- `ANDROID_KEYSTORE_BASE64`
- `KEYSTORE_PASSWORD`
- `KEY_ALIAS`
- `KEY_PASSWORD`

Then verify that:

- the decoded keystore is non-empty
- the alias exists in the keystore
- `apksigner verify` succeeds on the final APK

## 9. Android: split APK or custom packaging problems

### Symptoms
- wrong artifact selected
- install failures on devices expecting a universal artifact
- Flutter/native libraries present in one artifact but not the final release asset

### Recovery
- return to the standard `flutter build apk --release` path
- avoid split-per-ABI recovery experiments until base validity is restored
- validate the exact APK that will be published

## 10. Android: CI/CD recovery steps

When CI fails but the code seems correct, treat it as a pipeline forensic exercise.

### Minimum sequence
1. inspect release build log
2. inspect APK forensics log
3. inspect native library verification log
4. inspect signature log
5. inspect zipalign log
6. inspect content listing log
7. inspect resolved artifact path

### Questions to answer
- was the correct APK selected?
- is it signed?
- is it aligned?
- does it contain Flutter engine libraries?
- does it contain the native runtime libraries expected for ARM64?

## 11. Local runtime: model fails to load

### Likely causes
- corrupted GGUF file
- truncated model file
- unsupported model ID for Android runtime
- missing native bridge library

### Recovery
- validate model file exists and is large enough
- confirm selected model is in the Android allowlist
- confirm `libllama_bridge.so` is loadable for the packaged ABI

## 12. Voice runtime: ASR/TTS unavailable

### Likely causes
- Sherpa platform channel not registered
- runtime not initialized
- microphone/speaker path unavailable on current platform

### Recovery
- inspect voice engine status
- verify platform channel methods are implemented
- verify voice permissions and audio session readiness

## 13. Document retrieval returns weak results

### Why it may happen
The current vector memory is lightweight and local.
It uses compact hashed embeddings instead of a large external embedding service or vector database.

### Recovery / improvement path
- verify source text extraction succeeded
- confirm chunks were stored in SQLite
- re-index the document
- refine chunking or move to a stronger embedding backend in future work

## 14. Sync issues or conflicting state

### Current model
Sync is local-first and CRDT-based with last-write-wins semantics.

### Recovery
- verify local changes were recorded
- verify changeset export/import path
- inspect sync records in SQLite
- confirm peer merge happened with newer HLC values

## 15. General rule for maintainers

When troubleshooting AI-Orchestrator, do not ask only:

> “Did the app build?”

Also ask:

- did the right runtime path activate?
- did the right artifact get packaged?
- did local-first behavior remain intact?
- did platform constraints break architectural assumptions?
