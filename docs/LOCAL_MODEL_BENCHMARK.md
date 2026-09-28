# Local Phi vs Nemotron benchmark

This Debug Lab benchmark compares the two downloaded Android-local models on the
same device and runtime build:

- `phi3_5_mini`
- `nemotron3_nano_4b`

## Protocol

The runner executes the same eight short Italian cases for each model. The set
covers typo recovery (`sdd` -> `SSD`), stable factual knowledge, arithmetic,
a repeated identical prompt with an empty context, and controlled conversation
history.

Each request uses:

- Local runtime only;
- max output: 96 tokens;
- temperature: 0.5;
- top-p: 0.9;
- repeat penalty: 1.1.

The report records first-content latency, **native prompt prefill time**,
total latency, generated tokens, post-first-content decode throughput, requested
and observed GPU layers, batch/micro-batch, memory pressure, a battery-temperature
thermal proxy, and whether each case started cold/warm and ended with the native
session kept/released.

## Quality rubric

Scoring is deliberately small and deterministic. It checks only facts that can
be verified without a model judge. The Vulkan case requires both `API` and
`Khronos` and penalizes the known hallucinations "programming language" and
"designed/developed by Google".

The score is a diagnostic aid, not a general intelligence metric.

## Privacy

The benchmark prompts are fixed source-code test cases. Generated responses are
shown only in the local Debug Lab result dialog. RuntimeEventLog emits case IDs,
scores and technical timings, but not generated response text or user
conversation content.

## Vulkan GPU-layer matrix

Debug Lab exposes a separate **Vulkan 0 / 10 / full** matrix. It runs the same
small diagnostic subset for both local models with requested GPU-layer values:

- `0`: CPU baseline;
- `10`: partial Vulkan offload;
- `50`: full-offload request for the currently tested Phi/Nemotron models.

The value `50` is deliberately used instead of pretending that a request of
`99` proves something extra on these two models. Diagnostics already observed
about 33 offloaded layers for Phi and 43 for Nemotron, so a request of 50 covers
their full layer count. A future model with more than 50 offloadable layers must
be benchmarked separately; this matrix does **not** establish that 50 and 99 are
generally equivalent.

Changing the matrix value releases resident native sessions before the next
configuration is created. The production default remains unchanged after the
matrix, including on errors.

## Physical-device interpretation

The first model/configuration in a run may have a thermal/order advantage.
Compare the full matrix from one uninterrupted run and repeat in reverse order
when differences are close. A run that reaches critical memory is invalid and
must stop.

`prefill_ms` is measured inside the native llama.cpp bridge around the prompt
decode loop. The thermal value is Android's battery temperature from
`ACTION_BATTERY_CHANGED`; it is a stable, permission-free **device thermal
proxy**, not a CPU/GPU die-temperature measurement.

When post-generation RAM remains under pressure, the Android runtime is allowed
to release the resident native model session. This makes the benchmark reflect
a sustainable phone configuration rather than an unsafe warm-session peak.
