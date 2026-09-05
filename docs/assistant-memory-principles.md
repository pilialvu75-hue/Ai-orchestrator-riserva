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
