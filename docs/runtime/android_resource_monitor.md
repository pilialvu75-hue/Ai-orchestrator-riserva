# Android resource monitor

The chat runtime menu now exposes system available/total RAM, process RSS,
allocated native heap, memory pressure, native context/batch/microbatch,
reported GPU layer assignment and successful native decode calls.

Sampling runs every two seconds while inference or a visible panel owns a
lease. It stops when both are inactive. A single platform request may remain
in flight; unavailable/expired readings become unknown, never zero. History
is capped at 60 samples. RESOURCE_SAMPLE/PROFILE/GUARD events use the existing
bounded persistent RuntimeEventLog and strict public Diagnostics projection.
There is no new network uploader, background service or permission.

## Protection

- Native session creation samples Android ActivityManager memory information.
- Critical pressure defers creation; pressure during an active request triggers
  the existing cancellation token and orderly off-UI session release.
- Profile changes happen inside the serial queue, before native generation.
- Phi-3.5 starts with context 2048, batch 128, microbatch 64.
- Elevated pressure selects context 2048, batch 128, microbatch 32.
- Other models keep context 4096, batch 512, microbatch 128 without pressure.
- Existing smaller sessions are retained when pressure recovers, avoiding
  repeated reloads. A session with larger limits is recreated under pressure.
- Prompt and generation budgeting use the actual native context capacity.
- UI_HIDDEN/background trim callbacks are not treated as critical RAM events.

The low-memory boolean, running-critical trim signal and available RAM below
Android's threshold are critical evidence. Elevated pressure includes running
low/moderate signals and headroom less than 512 MiB above Android's threshold.
These are conservative heuristics, not a prediction of the Android killer.
Mmap-backed model pages, other apps and later decode allocation still matter.

## GPU evidence and limits

The compiled backend is displayed separately. The bridge captures llama.cpp's
model-load `offloaded N/M layers to GPU` report for its pinned revision. This is the upstream placement report, not an independent hardware utilization counter. Missing
reports remain unknown. CPU-only devices plus disabled operation/KV offload
report zero layers. Decode counts show runtime progress, not GPU utilization.
No portable GPU busy-percent or per-process GPU-memory sensor is implemented;
the panel explicitly shows these as unavailable. GPU assignment is not
increased automatically, and the existing CPU baseline remains in effect.

## Device acceptance (not yet proven by desktop checks)

1. Open the runtime menu; verify RAM values and updates every two seconds.
2. Run Phi and inspect RESOURCE_PROFILE and actual context/batch/microbatch.
3. Close the menu during generation; resource samples must continue.
4. Run ten sequential prompts with Phi and Nemotron; compare load time, first
   token, RSS and pressure. Confirm clean EOS and cancellation.
5. Export Diagnostics manually and verify resource samples accompany the
   Android process exit history after any unexpected termination.
6. In a separately controlled GPU-enabled build, confirm reported assigned
   layers. Do not equate backend availability or decode calls with GPU busy %.

References:
- https://developer.android.com/reference/android/app/ActivityManager.MemoryInfo
- https://developer.android.com/reference/android/content/ComponentCallbacks2
- third_party/llama.cpp/src/llama-model.cpp (pinned submodule)

Remaining roadmap: device tuning, optional vendor-supported GPU counters,
measured GPU profile selection, long-session validation, Voice/Live integration.

## Implementation validation

- 23 targeted Flutter tests passed (monitor ownership/pressure/missing readings,
  extended native creation ABI, off-UI lifecycle, token budgets and Diagnostics).
- Dart analysis of the changed runtime/UI/Diagnostics scope: no errors; an
  existing unused-variable warning remains in generation startup.
- Native aggregated entrypoint passed C++17 syntax checks against the exact
  pinned llama.cpp headers with both CPU and GGML_USE_VULKAN configuration.
- Android APK build and physical S24 FE measurements remain pending.

## Live panel and diagnostic parity

The open metrics popup subscribes to runtime, hardware and selected-mode
controllers so its token count, elapsed time and status update without reopening.
The resource panel shows the sample clock time and Android's memory threshold.
Partial memory readings display unknown pressure rather than normal pressure.

RESOURCE_SAMPLE now additionally records total/threshold RAM, pressure category,
low-memory and trim signals, and actual context/batch/microbatch. The public
projection accepts both legacy samples and the extended strict numeric schema.
Logger or individual cancellation-listener failures cannot prevent other RAM
guards from being notified. A disposed monitor cannot restart polling.

These changes improve observability and guard resilience; they do not establish
GPU utilization or measured inference speed gains. Validation is tracked in the
associated pull request; device measurements remain required.

## Per-attempt inference timing

INFERENCE_TIMING records the response model, requested runtime mode, retry
attempt, milliseconds to the first non-empty content, total attempt time,
provider-reported token count and non-final text chunk count. It starts at
routing, so it excludes preprocessing performed before routing. A missing
first content is -1; provider counts are reported as supplied, not estimated
from string chunks. The strict public projection omits prompt/response text.
STREAM_TOKEN_COUNT now uses the terminal provider count rather than counting
the final full-response chunk again.

Present-tense office-holder identity questions request fresh web evidence even
without words such as "today". Explicit historical years, first office-holders
and past-tense questions retain the ordinary path. Existing offline and
post-search continuation safeguards still apply. This does not establish the
cause of the initial latency from a tail-only device log.

## Selection consistency and memory termination

Background model-update results merge into the latest model-list state, so they
cannot restore a selection captured before an asynchronous check. Selection
writes run in order and failed preference writes are surfaced instead of showing
an unsaved selection. Inference continues to resolve the selected model for each
request; regression coverage switches models in the same chat.

Critical memory signals now emit a `critical_memory` terminal error immediately,
before closing the stream, and retain a failed monitor state during cleanup.
Cancellation and native session release remain enabled, including Android trim
level 15 even when available RAM exceeds the low-memory threshold. Local error
timing keeps the resolved request model when the provider omits it. This change
does not enable GPU offload or establish a device performance improvement.
