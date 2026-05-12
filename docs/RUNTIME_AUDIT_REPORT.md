# Runtime Stabilization Audit Report

**Scope:** Android llama.cpp FFI runtime pipeline  
**Status:** Fixes applied — see "Changes Made" section  

---

## 1. Audit Scope

Files fully audited:

| File | Area |
|------|------|
| `native/android/llama_bridge.cpp` | Native C bridge, generation thread, ring buffer, FFI API |
| `native/android/llama_bridge.h` | Public C API contract |
| `lib/core/runtime/inference/android_ffi_runtime_provider.dart` | Dart FFI host, polling loop, timeout guards |
| `lib/core/runtime/inference/local_runtime_provider.dart` | Desktop/process-based runtime |
| `lib/core/runtime/inference/ffi/llama_bindings.dart` | Dart FFI bindings |
| `lib/core/runtime/inference/ffi/llama_ffi_loader.dart` | Library loader |
| `lib/core/runtime/inference/cancellation_token.dart` | Cancellation contract |
| `lib/core/runtime/inference/inference_service.dart` | Orchestration layer |
| `lib/core/runtime/inference/local_runtime_status.dart` | Monitor / state machine |
| `lib/core/runtime/inference/inference_response.dart` | Response model |

Files **not** in scope for this audit (confirmed stable):

- `lib/features/` — Flutter UI, BLoC, feature modules
- `lib/injection_container.dart` — Dependency injection
- `lib/core/orchestrator/` — Orchestrator abstractions
- `android/app/build.gradle` / CMake — Build pipeline

---

## 2. Diagnostic Findings

### BUG-1 — EOS Token Race in `llb_poll_token` *(CRITICAL)*

**Location:** `native/android/llama_bridge.cpp` → `llb_poll_token`  
**Severity:** Critical — causes truncated / incomplete responses at end of generation  

**Root cause:**  
The ring-buffer check and the `g_gen_state` check were not atomic.  The race window:

```
[Dart polling] acquire ring lock → ring empty → RELEASE lock
[Gen thread]   push_token(last_piece)           ← acquires ring lock, pushes, releases
[Gen thread]   g_gen_state.store(1)             ← done
[Dart polling] read g_gen_state == 1 → return 2 (done)  ← LAST TOKEN LOST
```

The final token is in the ring but the Dart side has already returned "generation complete".

**Fix applied:** Hold the ring mutex through the `g_gen_state` read.  When the lock is held:
- If the gen thread is mid-`push_token` it blocks; Dart sees `state = 0` and retries.
- If `state == 1` while the lock is held, `push_token` already ran and the ring is
  truly empty or already drained — so returning "done" is correct.

---

### BUG-2 — Premature `g_cancel_flag` Clear in `llb_free_model` *(HIGH)*

**Location:** `native/android/llama_bridge.cpp` → `llb_free_model`, cleanup-thread path  
**Severity:** High — stale generation thread continues running after cancellation  

**Root cause:**  
After spawning the detached cleanup thread, `llb_free_model` immediately called
`g_cancel_flag.store(false)`.  The old gen thread (now being waited on inside
the cleanup thread) had not necessarily seen `cancel = true` yet.  Subsequent
calls to `llb_start_gen` would clear the flag again at `g_cancel_flag.store(false)`
inside `llb_start_gen`, but the window between the two clears allowed the old
gen thread to run with `g_cancel_flag = false`, potentially:

1. Continuing to push tokens into the ring buffer.
2. Setting `g_gen_state` to a terminal value, which could prematurely end a
   new inference that had just started.

**Fix applied:** Removed `g_cancel_flag.store(false)` from the cleanup-thread path
in `llb_free_model`.  `llb_start_gen` already resets the flag immediately before
spawning the new generation thread; this is the correct single owner of that reset.

---

### BUG-3 — No Generation Epoch: Stale Thread Can Corrupt New Inference *(HIGH)*

**Location:** `native/android/llama_bridge.cpp` — global state  
**Severity:** High — token and state corruption across back-to-back inferences  

**Root cause:**  
All global state (`g_gen_state`, `g_gen_finished`, ring buffer) was unversioned.
A stale generation thread (handed off to a cleanup thread after a reset, still
running inside a blocking `llama_decode()`) could:

1. Push tokens tagged as belonging to the OLD inference into the ring buffer
   that is now being drained by a NEW inference.
2. Write `g_gen_state = 1` (done) after a new inference had already set it to `0`
   (generating), causing the Dart polling loop to exit prematurely.

**Fix applied:**  
Introduced a monotonically-increasing `g_gen_epoch` (`std::atomic<uint64_t>`).

- `llb_start_gen` increments the epoch **before** resetting state, so the new
  epoch is visible to stale threads immediately.
- Each `GenArgs` carries the epoch captured at spawn time.
- `push_token` embeds the epoch in every `RingEntry`.
- `gen_update_state` / `gen_mark_finished` are epoch-gated helper functions:
  a stale thread's terminal state updates are silently dropped if the current
  global epoch has advanced past the thread's own epoch.
- `llb_poll_token` drains ring entries with stale epochs before processing.

---

## 3. Architecture Observations (No Code Change Required)

### OBS-1 — Model Load Blocks Dart UI Thread *(MEDIUM)*

`bindings.loadModel(modelPath)` is a synchronous FFI call that internally runs
`llama_model_load_from_file`, which can take 3–15 seconds for 1–2 B parameter
GGUF files on mobile.  This blocks the Flutter event loop, freezing the UI.

`await Future<void>.delayed(Duration.zero)` at the call site yields the event
loop **before** the call but not **during** it.

**Recommendation:** Run model loading inside `Isolate.run()` with a bounded
timeout.  The `libllama_bridge.so` native library is process-global; symbols
loaded from one Dart isolate are accessible from another.  The bindings would
need to be re-constructed inside the isolate (one `DynamicLibrary.open()` call
per isolate), but this is safe because `llb_load_model` operates on
process-level globals and the serial inference queue (`_runInferenceSerially`)
prevents concurrent access.

This change is deferred to a follow-up because it requires restructuring
`AndroidFfiRuntimeProvider` and carries non-trivial regression risk.

---

### OBS-2 — Serial Inference Queue *(Correct)*

`_runInferenceSerially` in `AndroidFfiRuntimeProvider` correctly serialises all
inference calls through a promise chain.  Concurrent inference requests queue
behind the current one without interleaving native calls.  No change needed.

---

### OBS-3 — Stall Watchdog Alignment *(Correct)*

`_stalledInferenceTimeout` in Dart (45 s) and `kNoTokenStallMillis` in C++
(45 000 ms) are aligned.  Both layers independently detect a "no first token"
stall.  The native layer sets `g_gen_state = -1` with error text
`"Local model stalled during inference."`, which the Dart layer explicitly
pattern-matches.  The defence-in-depth is intentional and correct.

---

### OBS-4 — `LocalRuntimeMonitor` Thread Safety *(Correct)*

`LocalRuntimeMonitor.update()` is called only from the Flutter main isolate
(via async callbacks in `streamInference`).  Dart single-isolate concurrency
guarantees sequential execution.  No mutex needed.

---

### OBS-5 — `_finishWithError` Sync Close *(Acceptable)*

`_finishWithError` calls `ctrl.close()` synchronously without `await`.
`StreamController.close()` is non-blocking; the returned `Future` completes
when the last subscriber is done, but ignoring it does not prevent cleanup.
No change needed.

---

## 4. Changes Made

| File | Change |
|------|--------|
| `native/android/llama_bridge.cpp` | Added `<cinttypes>` include |
| `native/android/llama_bridge.cpp` | Added `RingEntry { piece, epoch }` struct; replaced `std::queue<std::string>` with `std::queue<RingEntry>` |
| `native/android/llama_bridge.cpp` | Added `g_gen_epoch` atomic counter |
| `native/android/llama_bridge.cpp` | Added `gen_update_state()` / `gen_mark_finished()` epoch-gated helpers |
| `native/android/llama_bridge.cpp` | Added `epoch` field to `GenArgs` |
| `native/android/llama_bridge.cpp` | `generation_thread` captures `my_epoch`; all `g_gen_state.store()` / `g_gen_finished.store(true)` calls replaced with epoch-gated helpers |
| `native/android/llama_bridge.cpp` | `push_token` signature extended with `epoch` parameter; all call-sites updated |
| `native/android/llama_bridge.cpp` | `llb_poll_token` restructured: ring lock held through state check (fixes BUG-1); stale-epoch draining added (fixes BUG-3) |
| `native/android/llama_bridge.cpp` | `llb_start_gen` increments `g_gen_epoch` before resetting state; epoch passed to `GenArgs` |
| `native/android/llama_bridge.cpp` | `llb_free_model` cleanup-thread path: removed premature `g_cancel_flag.store(false)` (fixes BUG-2) |

No Dart files were modified.  All existing API contracts (`llama_bridge.h`,
`LlamaBridgeBindings`, `RuntimeInferenceProvider`) are unchanged.

---

## 5. What Was NOT Changed

Per the stabilization rules:

- Flutter UI, BLoC, feature modules — **untouched**
- Dependency injection container — **untouched**
- `LocalRuntimeProvider` (desktop/process runtime) — **untouched**
- `InferenceService` orchestration layer — **untouched**
- Android `build.gradle` / `CMakeLists.txt` — **untouched**
- Public `llama_bridge.h` C API — **untouched**
- `LlamaBridgeBindings` Dart wrapper — **untouched**
- Cloud runtime, hybrid runtime — **untouched**

---

## 6. Known Limitations

| ID | Description | Mitigation |
|----|-------------|------------|
| LIM-1 | Model load blocks Flutter UI thread (OBS-1) | `await Future<void>.delayed(Duration.zero)` before load gives UI one frame; deferred to follow-up |
| LIM-2 | `libllama_bridge.so` must be pre-built and placed in `android/app/src/main/jniLibs/<abi>/` | See `native/android/README.md` for build instructions |
| LIM-3 | `kMaxGeneratedTokens = 256` cap in native layer; Dart `_safeMaxTokens = 128` is the effective limit | Sufficient for on-device mobile inference; raise both constants if longer outputs are needed |
| LIM-4 | No GPU acceleration (n_gpu_layers = 0) | Enable by recompiling with Vulkan/OpenCL ggml backend and setting n_gpu_layers > 0 in `llb_load_model` |

---

## 7. Build & Validation Notes

To rebuild the native bridge after these changes:

```bash
# From repo root
cmake \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DCMAKE_BUILD_TYPE=Release \
  -S native/android \
  -B build/android/arm64-v8a

cmake --build build/android/arm64-v8a --target llama_bridge

cp build/android/arm64-v8a/libllama_bridge.so \
   android/app/src/main/jniLibs/arm64-v8a/
```

Repeat for `x86_64` if emulator support is needed.

Flutter build validation:
```bash
flutter build apk --debug
flutter build apk --release
```
