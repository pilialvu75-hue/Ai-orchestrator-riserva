1. Execution map

- `streamInference(request, cancellationToken)` enters outer `try`, logs, sets:
  - `controller = StreamController<InferenceResponse>()`
  - `firstFfiInvocationAttempted = false`
  - `firstFfiInvocationCompleted = false`
  - local async closure `fatalEarlyExit(...)` (`lib/core/runtime/inference/android_ffi_runtime_provider.dart:463-503`)
  - `controller.onCancel` callback (`505-516`)
- It starts an unawaited async IIFE `() async { ... }();`, then returns `controller.stream` immediately (`518-523`, `1708-1713`).

- Async IIFE:
  - `await _runInferenceSerially(() async { ... })` (`522-523`)
  - `_runInferenceSerially` appends work onto `_inferenceTail.then((_) async { await action(); })`; this is the serialization boundary (`2192-2218`).

- Serialized action closure initializes:
  - `sessionId = request.sessionId.trim().isEmpty ? 'unknown' : request.sessionId.trim()`
  - `isVerificationSession = sessionId == _forensicSelfTestSessionId`
  - `dartThreadId = _currentThreadId()` (`524-529`)

- Pre-FFI guards / early exits:
  - `!isVerificationSession && !_claimInferenceSlot(sessionId)`  -> `fatalEarlyExit(...)` -> `_finishWithRuntimeError(...)` -> return (`538-552`, `2257-2265`, `2477-2496`)
  - `cancellationToken.isCancelled` -> `fatalEarlyExit(..., state: cancelled)` -> return (`558-569`)
  - `modelPath = request.modelPath`, `modelId = request.modelId` (`570-571`)
  - `modelPath == null || modelPath.isEmpty || modelId == null` -> `clearRuntimeVerification()` -> `_updateRuntimeStatus(modelMissing)` -> `_syncLifecycleState(modelMissing)` -> `runtimeStateMachine.reset()` -> `fatalEarlyExit(...)` -> return (`579-595`, `2651-2667`, `2669-2743`, `155`, `2711-2715`)
  - file existence / size logging only (`598-615`)
  - unsupported model and not developer mode -> `clearRuntimeVerification()` -> `_updateRuntimeStatus(failed)` -> `_syncLifecycleState(failed)` -> `runtimeStateMachine.markFailed()` -> `fatalEarlyExit(...)` -> return (`617-650`, `2736-2740`, `175`)
  - synchronous model validation:
    - `modelValidationError = _validateModelFileForRuntime(modelPath)` (`661-664`, `2564-2593`)
    - thrown exception -> `fatalEarlyExit(...)` -> return (`665-675`)
    - non-null validation error -> `clearRuntimeVerification()` -> `_updateRuntimeStatus(failed)` -> `runtimeStateMachine.markFailed()` -> `fatalEarlyExit(...)` -> return (`677-694`)

- Warmup branch:
  - non-self-test: `await _ensureWarmup(sessionId, modelPath)` (`697-712`)
  - self-test: skips warmup (`713-715`)

- Async boundary detail: `_ensureWarmup` is async, but when it executes `_warmupFuture = _runWarmup(modelPath: modelPath)` (`2287-2293`), `_runWarmup` runs synchronously until first `await`. So first native entry can happen during assignment of `_warmupFuture`.

- `_ensureWarmup` flow (`2270-2335`):
  - `shouldReuseRuntimeVerification(modelPath)` short-circuit:
    - if reusable -> verification monitor update + return true (`2277-2285`, `332-368`)
    - if monitor status is `runtimeUnavailable/uninitialized/failed/completed`: `_updateRuntimeStatus(ready)` -> `_syncLifecycleState(ready)` -> `runtimeStateMachine.markVerified()`; else directly `runtimeStateMachine.markVerified()` (`348-364`, `2726-2728`, `168`)
  - else assigns `_warmupFuture = _runWarmup(...)`
  - then `await _warmupFuture!`
  - catch: warmup failure is observational-only -> `clearRuntimeVerification()` -> `_updateRuntimeStatus(runtimeUnavailable)` -> `_syncLifecycleState(runtimeUnavailable)` -> `runtimeStateMachine.markHealthy()` -> return false (`2311-2333`, `2716-2721`, `159`)

- `_runWarmup` pre-native setup (`2337-2364`):
  - `_updateRuntimeStatus(loading, resetProgress: true)` -> `_syncLifecycleState(loading)` -> `runtimeStateMachine.markLoading()` (`2346-2350`, `2722-2725`, `157`)
  - ABI guard: unsupported ABI -> throw `StateError` (`2351-2353`)
  - library guard: `!_ensureLibraryLoaded()` -> throw `StateError` (`2354-2355`)

- After first native boundary, stream flow continues:
  - if warmup skipped/failed, explicit library check `!_ensureLibraryLoaded()` can early-exit `ffiMissing` (`717-733`)
  - `bindings = _bindings!` (`735`)
  - `_updateRuntimeStatus(loading)` + `await Future<void>.delayed(Duration.zero)` (`738-741`)
  - `nativeSessionId = await _runNativeCallWithTimeout(() => _ensureNativeSession(...))` (`747-760`)
  - session active validation (`784-801`)
  - `prompt = _composePrompt(...)` (`808-812`, `2545-2562`)
  - prompt/token guards and `_updateRuntimeStatus(tokenizing)` (`813-858`, `832-836`)
  - `bindings.startGeneration(...)` via `_runNativeCallWithTimeout` (`922-969`)
  - `_updateRuntimeStatus(inferencing)` (`1035-1041`)
  - poll loop:
    - `status == 1`: token decode, first-token frees prompt ptr, `recordVerificationSuccess(...)`, `_updateRuntimeStatus(streaming)`, `controller.add(token)` (`1256-1448`, `2746-2780`)
    - `status == 2`: EOS, `recordVerificationSuccess(...)`, `controller.add(finalChunk)`, `_updateRuntimeStatus(completed)` (`1479-1517`)
    - `status == -99`: cancelled, `clearRuntimeVerification()`, `_finishWithRuntimeError(...)`, `_updateRuntimeStatus(runtimeUnavailable)` (`1518-1539`)
    - `status == -1`: native error, `_safeLastError(...)`, `_updateRuntimeStatus(failed)`, finish error/partial (`1540-1588`)
    - `status == 0`: idle backoff with `await Future<void>.delayed(...)` (`1589-1604`)
  - polling `finally`: free prompt ptr, optional `_safeResetRuntime(...)`, normalize state to ready if still active states, free token buffer, close stream (`1607-1651`)
  - action `catch/finally`: unhandled exception handling, pre-FFI classification, inference slot release, session end (`1653-1697`)

2. Call graph (to first native boundary)

| File | Class | Method | Parameters | Return | Early returns | Exceptions handled |
|---|---|---|---|---|---|---|
| `lib/core/runtime/inference/android_ffi_runtime_provider.dart` | `AndroidFfiRuntimeProvider` | `streamInference` | `InferenceRequest request, CancellationToken cancellationToken` | `TokenStream` | immediate `controller.stream` return + many pre-FFI returns in async closure | outer + inner async try/catch |
| same | local closure | `fatalEarlyExit` | `String sessionId, {branch, reason, stage, details, state}` | `Future<void>` | if closed controller, skip finishing | none |
| same | `AndroidFfiRuntimeProvider` | `_runInferenceSerially` | `Future<void> Function() action` | `Future<void>` | none | catches in queued action and rethrows |
| same | `AndroidFfiRuntimeProvider` | `_claimInferenceSlot` | `String sessionId` | `bool` | returns false if already active | none |
| same | `AndroidFfiRuntimeProvider` | `_validateModelFileForRuntime` | `String modelPath` | `String?` | error-string returns for multiple guards | catches file I/O and returns readable error |
| same | `AndroidFfiRuntimeProvider` | `_ensureWarmup` | `String sessionId, String modelPath` | `Future<bool>` | returns true on verification reuse; false on observational warmup failure | catches warmup errors and converts to false |
| same | `AndroidFfiRuntimeProvider` | `shouldReuseRuntimeVerification` | `String modelPath` | `bool` | direct reusable return | none |
| same | `AndroidFfiRuntimeProvider` | `_runWarmup` | `String modelPath` | `Future<void>` | none | catches/logs/rethrows, always runs finally |
| same | `AndroidFfiRuntimeProvider` | `_updateRuntimeStatus` | `LocalRuntimeStatus status, {message, tokensGenerated, elapsed, startedAt, resetProgress, reason, origin}` | `void` | return if `_inVerificationScope` | none |
| same | `AndroidFfiRuntimeProvider` | `_syncLifecycleState` | `LocalRuntimeStatus status, {required reason, required origin}` | `void` | case-based return | none |
| `lib/core/runtime/inference/runtime_state_machine.dart` | `RuntimeStateMachine` | `markLoading` | none | `void` | none | none |
| same | `RuntimeStateMachine` | `transition` | `RuntimeLifecycleEvent event` | `RuntimeLifecycleState` | no-op return if disallowed or unchanged transition | none |
| `lib/core/runtime/inference/android_ffi_runtime_provider.dart` | `AndroidFfiRuntimeProvider` | `_ensureLibraryLoaded` | none | `bool` | true during in-progress load; cached return when load already attempted; false if loader fails | finally clears load flag |
| `lib/core/runtime/inference/ffi/llama_ffi_loader.dart` | `LlamaFfiLoader` | `tryLoadBridgeLibrary` | `{void Function(String message)? log}` | `LlamaFfiLibraryHandle?` | null for unsupported ABI/load/symbol failures | catches open/bind failures |
| `lib/core/runtime/inference/ffi/llama_bindings.dart` | `LlamaBridgeBindings` | `initBackend` | none | `void` | none | none |

3. First native binding identified

- First native boundary on fresh path:
  - `AndroidFfiRuntimeProvider._ensureLibraryLoaded()` -> `_bindings!.initBackend()`
  - call site: `lib/core/runtime/inference/android_ffi_runtime_provider.dart:177-181`
  - binding wrapper: `lib/core/runtime/inference/ffi/llama_bindings.dart:49`

- Path-sensitive caveat:
  - if `_loadAttempted == true` and bindings already cached, `initBackend()` is skipped.
  - then first native call becomes either:
    - `bindings.sessionIsActive(existingSessionId)` in `_ensureNativeSession` reuse path (`2028-2038`), or
    - `bindings.createSession(modelPath, nGpuLayers: desiredGpuLayers)` (`2065-2067`).

4. Argument trace (first native call = `initBackend()`)

- Invocation: `_bindings!.initBackend()` (`android_ffi_runtime_provider.dart:181`)
- Callee: `LlamaBridgeBindings.initBackend()` -> `_initBackend()` (`llama_bindings.dart:49`)

Arguments:

| Argument | Source variable | Origin location | Nullable/non-nullable | Validation before call | Possible invalid states |
|---|---|---|---|---|---|
| none | n/a | `initBackend` has no params | n/a | n/a | n/a |

Implicit receiver context:

| Item | Source variable | Origin location | Nullable/non-nullable | Validation before call | Possible invalid states |
|---|---|---|---|---|---|
| receiver | `_bindings!` | assigned from `handle.bindings` after `handle = LlamaFfiLoader.tryLoadBridgeLibrary(log: _log)` (`177-180`) | forced non-null at callsite (`!`) | `if (handle == null) return false;` before assignment/call | bad handle only if loader produced inconsistent handle; loader returns null on symbol-binding failure (`llama_ffi_loader.dart:63-83`) |

5. Crash surface map (before first native binding call)

| Location | Failure Condition | Existing Guard | Result |
|---|---|---|---|
| `streamInference` `538-552` | recursive inference (`_activeInferenceSessions` already contains session) | `_claimInferenceSlot(sessionId)` | `fatalEarlyExit`; stream runtime error; no native call |
| `streamInference` `559-568` | preflight cancellation | `cancellationToken.isCancelled` | cancelled early-exit; no native call |
| `streamInference` `579-595` | null/empty model path or null model ID | explicit check | verification cleared; status `modelMissing`; state reset; early-exit |
| `streamInference` `617-650` | unsupported model (outside whitelist) in non-developer mode | `_androidSafeModelIds.contains(modelId)` with developer bypass | status `failed`; state failed; early-exit |
| `streamInference` `662-675` | unexpected thrown error in model validation | `try/catch` around `_validateModelFileForRuntime` | early-exit before FFI |
| `_validateModelFileForRuntime` `2566-2589` | file missing, wrong extension, truncated/corrupt size, invalid GGUF header, unreadable file | explicit checks + catch fallback | returns validation error string; caller fails pre-FFI |
| `_ensureWarmup` `2277-2285` | reusable verification path | `shouldReuseRuntimeVerification` | returns true; warmup/native boundary deferred |
| `_runWarmup` `2351-2353` | unsupported ABI | `LlamaFfiLoader.isCurrentPlatformSupported` | throws; caught as observational warmup failure; no native binding |
| `_ensureLibraryLoaded` `173` | load already attempted but invalid cached state | `_loadAttempted` cached path | returns false -> warmup/library failure path |
| `LlamaFfiLoader.tryLoadBridgeLibrary` `41-47` | unsupported ABI at loader | ABI guard | returns null; `_ensureLibraryLoaded` false |
| same `49-61` | `DynamicLibrary.open` failure | `try/catch` around open | returns null; `_ensureLibraryLoaded` false |
| same `63-83` | symbol lookup/bind failure constructing bindings | `try/catch` around bind | returns null; `_ensureLibraryLoaded` false |
