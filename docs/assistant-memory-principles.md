# Assistant memory requirements

Design requirements agreed with the owner; not a claim of implemented memory features.

- Keep concepts, confirmed facts, decisions, reasons, changes and unresolved
  problems, rather than conversational filler or repeated messages.
- Separate current state from essential history. Keep provenance and dates;
  an assistant suggestion is not a user-confirmed fact.
- Important subjects and active projects must remain available offline until
  completion. Preserve goals, direction, constraints, decisions, relevant files,
  implementation state and open tasks. Summaries must not silently discard
  details necessary to continue the project.
- Local storage retention is distinct from the model's prompt window: retrieve
  relevant information without inserting the entire project into every prompt.
- Do not automatically evict active/pinned project knowledge. Surface insufficient
  storage instead of silently removing it. Completion permits an explicit archive
  decision; it is not automatic deletion.
- A future personal server may keep detailed history and synchronize devices.
  Offline devices must retain pinned subjects and active projects. Remote-only
  details must be identified as unavailable when disconnected, not fabricated.
- Provide user inspection, correction, deletion and offline pinning. Coordinate
  shared contracts with the separate Cloud and Workshop workstreams.

## Model-neutral knowledge and experience (1 November 2026)

- Aivexus owns the memory, not Qwen, Phi, Nemotron, a Cloud provider or a device-specific runtime. Provider/model changes must not reset or fork the canonical user-approved knowledge base.
- Distinguish **facts** from **verified reusable procedures**. A model may propose a procedure as a candidate; only independently verified test evidence allows its promotion to a confirmed, reusable procedure. Reading is not permission to execute it.
- Record provenance, status and scope, and expose bounded relevant confirmed memories through the same shared chat gateway to each authorized runtime. Candidate/model-generated output is never silently promoted.
- A memory that is conversation-scoped does not become user-wide merely because the model changes. Personal user-wide memory can cross sessions only within the authorized owner scope. A future multi-account release must isolate all stores and caches by real owner identity, not a UI label.
- Cloud inference and remote synchronization are separate consent boundaries. Selecting a cloud model must not silently authorize sending unrelated private memories. Provider selection, upload consent and query-time minimal disclosure require explicit independent policy controls before rollout.
- Every supported Flutter platform should share record semantics and portable serialization. Actual cross-device sharing needs approved encrypted pairing/sync and offline cache; a portable record test alone is **not** evidence that live synchronization works.
- Use native language understanding and model-independent retrieval, not exhaustive hard-coded question patterns. Keep cold start, first-token latency, RAM, token budget and offline behavior within existing device constraints.
