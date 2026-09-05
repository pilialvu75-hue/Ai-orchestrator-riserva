# Assistant reliability audit — 2026-09-05

Base: `e1b21687da0a99213a058ae78606517248265ae6`. This is a partial remediation,
not a certification that the assistant or background downloads are working.

## Changes in this patch

- Preserve a generation's failure for its caller while independently recovering
  the serial queue. Previously the concurrency manager swallowed that failure,
  potentially preventing the stream's error/close path from executing.
- Match complete model-size components. For example, `1.7b` must not match `7b`,
  and `3.8b` must not match `8b`. Keep the existing Phi-specific defaults.
- Reject negative native tokenization results (insufficient buffer capacity)
  instead of replacing the conversation with `Hello`. Preserve one-token input.
  This reports overflow; it does not yet implement token-budgeted history pruning.
- Apply the 90-second absolute deadline only before the first output token.
  Productive streaming remains bounded by native max tokens, cancellation,
  repetition guards and the existing 35-second no-progress watchdog.

## Unresolved work

| Area | Evidence / risk | Required follow-up |
| --- | --- | --- |
| Context | `local_prompt_templates.dart` budgets characters, not actual tokens or output reserve | Tokenizer-aware history budget; preserve current question and system instructions; explicit handling of a single oversized question |
| Native context | The generation loop can exhaust remaining context | Validate prompt plus output capacity and expose a meaningful terminal reason |
| Performance | Native bridge logs complete prompts and individual tokens | Gate verbose diagnostics; measure first-token latency, tokens/sec and memory on devices |
| Repeated turns | Queue failure handling alone cannot prove absence of native lifetime or memory faults | Stress cancellation, regeneration, model switching and 30+ consecutive exchanges |
| Templates | Model families have different prompt and stop-token requirements | Verify Phi3.5, Qwen, Llama and Gemma against supported GGUF templates; fail clearly for unsupported models |
| Download UI | Model-download progress callbacks call `add` on the initiating BLoC | Decouple job ownership from screens; guard disposed observers; reattach progress after navigation |
| OS background | Current Dart downloads and resumable partial files are not a durable Android job system | Implement one persistent job registry and Android-supported transfer execution for APK, GGUF and voice assets |
| Duplicate downloads | Shared destination/partial files need single-job ownership | Deduplicate by destination, serialize validation/extraction, persist cancellation and retry state |

Background acceptance must distinguish changing screens, backgrounding the app,
process recreation and explicit force-stop. Do not promise execution after force-stop.
Keep APK installation user-initiated in the foreground. Preserve existing file
validation, APK identity/signature checks and partial-download recovery.

## Other repositories checked for reusable solutions

This was a targeted inspection of repository trees and relevant candidate files,
not a complete security or correctness review of every file.

| Repository | Finding relevant to this task |
| --- | --- |
| AI-Orchestrator-Core | Older global native ABI (`llb_load_model`, `llb_start_gen`) and a 128-token limit. Do not transplant this bridge into the current session-based runtime. |
| Mia | `mia-chat` and `mia-memory` entrypoints expose health/status scaffolding, not a conversational engine or memory implementation. |
| MobileIde | Flutter `AIEngine` returns predefined source-code templates rather than LLM inference. |
| FLUTTERIDE | Same kind of template-generating `AIEngine`; no conversational-runtime fix in that component. |
| Template-webview | `ContextEngine` stores an in-memory map; intelligent error analysis is a placeholder. |
| Template-AI-1 | FastAPI handler calls Ollama synchronously, without streaming or request timeout, with hard-coded `llama3.1`. Not an Android inference replacement. |

No ready-to-use fix was recovered from these inspected components. Repositories
previously listed as empty offer no known code candidate; this patch deletes none.

## Verification and release gates

- Pure Dart smoke checks passed for model profiles, serialization, failure
  propagation and queue recovery before the local Flutter setup was blocked.
- Added Flutter regression tests for model-size selection and serial task behavior.
- `git diff --check` passed.
- Flutter tests did not complete: the environment security reviewer blocked the
  setup process for an attempted cloud metadata endpoint access. Do not bypass it.
- Native compilation, polling integration tests and on-device tests are pending.
- No background-download implementation is included in this patch.

Before release, run the new tests plus existing runtime tests and build Android.
Then use Phi3.5 mini as the primary device test, with at least one supported Qwen,
Llama and Gemma model, including long histories, cancellation/retry, switching
models and output lasting over 90 seconds. Record device RAM, Android version,
model quantization, first-token latency, throughput, terminal reason and memory.
Evaluate factuality separately: runtime fixes cannot guarantee identical reasoning
quality, speed or absence of hallucinations across model sizes.

Track the overall goal in a parent issue, with separately verifiable tasks for
runtime reliability, model templates/context and persistent downloads. Closing
this patch must not automatically close that overall goal.
