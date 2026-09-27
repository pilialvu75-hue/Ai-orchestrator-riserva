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

The report records first-content latency, total latency, generated tokens,
post-first-content decode throughput, observed GPU layers, batch/micro-batch,
memory pressure, and whether each case started cold/warm and ended with the
native session kept/released.

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

## Physical-device interpretation

The first model in a run may have a thermal/order advantage. If the two models
finish close, repeat the benchmark with the opposite model order before drawing
a performance conclusion. A run that reaches critical memory is invalid and
must stop.

When post-generation RAM remains under pressure, the Android runtime is allowed
to release the resident native model session. This makes the benchmark reflect
a sustainable phone configuration rather than an unsafe warm-session peak.
