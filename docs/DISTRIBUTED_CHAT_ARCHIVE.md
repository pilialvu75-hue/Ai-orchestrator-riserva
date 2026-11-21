# AI-Orchestrator: distributed chat archive (offline-first)

Status: **phase A, catalog-only**. Tracking: issue #911. This design does not
claim a functioning cloud sync, encrypted export or remote restore.

## Separate three concerns

1. **SQLite on each device**: confirmed durable facts, provenance links, local
   conversation index and a catalog of possible off-device snapshots. No
   dependency on the network for local inference.
2. **Bounded local transcript cache**: recent, pinned and explicitly retained
   conversations. Device disk budget and model context/RAM budget are separate.
3. **Opt-in encrypted external archive**: versioned conversation snapshots,
   optionally referenced by multiple authorized devices. Transport adapters
   can target the user's selected storage; there is no default cloud service.

A durable memory item is a *claim*. A source transcript is *evidence*.
Link them by memory scope + key to a globally identifiable archive snapshot
and exact source message. An archived model response must never be silently
promoted to confirmed truth.

## Phase A implemented in this branch

- Additive SQLite schema version 7 creates `chat_archive_catalog` and
  `chat_archive_memory_links`, leaving chat messages and preferences untouched.
- `ChatArchiveCatalog` only registers **pending, immutable metadata pointers**,
  not chat contents or remote credentials. `remote_verified_at_ms` is null
  until a future authenticated downloader independently verifies the object.
- Origin device + original session ID preserve the distinction between
  colliding local session IDs such as `default` on separate devices.
- Source references are indexed without loading conversation text or invoking
  network operations.
- No migration deletes or rewrites user history; no UI, upload, eviction,
  background scheduling, or automatic promotion to memory is enabled.

## Multi-account isolation and shared learning (issues #911, #913)

The archive catalog is **owner-scoped**, not merely device-scoped. Device IDs
identify an origin but never establish a human identity. Every pointer and
provenance link has an opaque `owner_account_id`; catalog operations require an
owner bound to the caller's authenticated local account/profile context.
Missing owner is invalid. Queries, source lookups and writes are scoped to the
bound owner; identical `default` session IDs or memory keys from two people
cannot resolve to the other person's source. Tests exercise both owners in
one synthetic SQLite database.

**This is only a local catalog boundary, not completed authentication.**
Before distributing accounts, an authenticated identity lifecycle, per-user
key isolation, backend ACLs, device enrollment, logout/cache invalidation and
cross-profile end-to-end tests are mandatory. Do not derive an owner from text
in a model prompt or trust an owner attached to an unverified remote envelope.
Even catalog hashes and object keys can be private metadata; sharing the same
physical NAS does not authorize listing another owner's archive.

Separate replication policies:
- **Private facts**: profile preferences, conversation records, motorcycle
  ownership, sporting preferences, project facts and chat references replicate
  only to authorized devices of the same owner (or narrowly authorized project
  collaborators).
- **Shared skill candidates**: generic procedures proposed from opt-in
  experiences may enter a separate privacy-scrubbed, validated, versioned
  skill pipeline. Never publish raw transcripts or assume an LLM summary is
  anonymized. Review for sensitive facts, names, prompt injection, poisoning
  and factual correctness before other users receive the skill. A skill
  describing possible useful motorcycle comparison dimensions is not
  evidence of anyone's motorcycle or favourite sport.
- **Safety assistance**: provide support to the user at risk. Alerting another
  adult requires explicit and revocable opt-in by the person whose information
  would be shared. For minor accounts, implement authorized guardian roles
  and narrowly defined, proportionate safeguards with false-positive checks,
  minimal disclosures and applicable legal constraints. General curiosity
  about dangerous subjects is not sufficient grounds to notify family.
  No monitoring, risk notifications or cross-account sharing are active now.

Archive synchronization remains strictly opt-in. Never publish a
family beta (1.0.16) without the user's explicit authorization.

## Mandatory cross-device knowledge convergence (S24 -> ASUS example)

An archived transcript alone is **not** enough. Every authorized platform must
maintain its own up-to-date **SQLite materialized view** of user-confirmed
memories, recent chat indexes, remote archive pointers and source provenance,
subject to offline synchronization delays.

Example: on S24 the user discusses a motorbike and optionally captures a
photo. The event stream must make the conversation reference, tentative
identification and any user-confirmed fact discoverable on ASUS. ASUS must
answer "the bike we saw earlier" from its locally synchronized SQLite index,
then download a verified encrypted source/photo *on demand* if it needs to
identify the exact model. Current pricing/specifications require fresh
research and should never be invented. Source content may need additional
explicit authorization before being sent to a Cloud inference provider.

### Distinct replicable collections

- `confirmed_user_memory`: one event per record key + scope, with source,
  revision, origin node and authenticated delete/supersede tombstones.
- `conversation_catalog`: global conversation IDs, lightweight summaries
  explicitly reviewed/derived, pointers and metadata. These are retrieval
  cues, *not confirmed facts*.
- `archive_catalog`: immutable encrypted snapshot identities, provider IDs,
  ciphertext hashes and locations; a pointer does not assert it was uploaded.
- `project_memory` and `conversation_memory`: scoped to authorized project
  members and the originating conversation; never spill to all peers.
- `media_index`: only opaque references to encrypted photographs/attachments,
  with explicit retention and sync policy. The original is not sent to an AI
  provider simply because it is synchronized.

The full SQLite file never moves between devices. Use per-record
CRDT/HLC/revision event envelopes and local projections. Never use a plain LWW
overwrite of the current `assistant.durable_memory.v1:` JSON arrays: their
storage groups multiple records in one scope, causing concurrent writes to
overwrite independent updates. Never upgrade candidate/model-generated facts
to confirmed through replication.

There is already a `SyncManager` and a `sync_changes` SQLite log. Before
reusing its network transport on a cross-device trust boundary, implement
identity pairing, peer authentication, end-to-end encrypted transport/payload,
authorization per collection, rate/size limits, replay protection and
authenticated erasure tombstones. The current `LocalSyncServer` uses a
LAN HTTP listener bound to anyIPv4 with no obvious auth gate in its request
handler; **do not expose that service to the public Internet** or silently
activate it for the archive. All synchronization requires opt-in.

### Acceptance: 2 isolated SQLite databases

1. S24/test DB A records a synthetic motorbike conversation cue, archive
   reference and explicit confirmed memory. ASUS/test DB B is initially empty.
2. Authorized event transfer populates DB B without transferring full
   chat_history rows or opening the archive object; a query can identify the
   conversation by reference and is clear that model identification is not yet
   known.
3. Offline updates on A and B use different record keys and both survive
   the subsequent merge in either order; duplicate delivery is idempotent.
4. Delete/supersede on B propagates to A and is not resurrected by an old
   archive snapshot or delayed A-to-B transfer.
5. An unauthorized peer or a replayed/stale event cannot change memory.
   No raw tokens, photos, plaintext archives or API keys leak in logs.
6. On permanent connection loss, each device remains useful with local memory
   and accurately states when off-device sources cannot be retrieved.

**Phase A is only the metadata catalog and does not pass the cross-device
convergence criteria.** These are mandatory for later authenticated sync
phases, not promises about current installed builds.

## Next phases: completion criteria

**B — portable ciphertext snapshot (no network):**
A stable export format with schema version, globally unique archive ID,
origin device pseudonym, immutable revision, message IDs, attachment references,
timestamps and deterministic encoding. Encrypt locally with authenticated
encryption (AEAD); integrity-check both metadata and payload. Keep keys out of
plaintext catalog, URLs, logs and repository secrets. Round-trip on separate
isolated Android/desktop test databases. Never require the LLM to decrypt or
read all messages at once.

**C — authenticated remote storage adapter:**
Explicit opt-in to a user-chosen backend (e.g. WebDAV/NAS or S3-compatible,
where supported). Verify uploader permissions, remote content length,
hash and authenticated download/decryption before marking an archive verified.
Retry failed transfers without data loss. Limit mobile data/battery use.
No automatic upload of sensitive attachments or credentials. Do not treat a
GitHub code repository or a public release as private user storage.

**D — retention and local cache:**
Only a verified, recoverable remote copy can become *eligible* for local
eviction; even then enforce the user's backup/retention policy, pin and
active-context leases. Prefer keeping original recent chats until a safety
policy is tested on disposable data. The first version does not delete any
transcript. Archive is not Delete. Local semantic chunking/embedding and
off-device storage must not accidentally duplicate whole histories in RAM.

**E — selective retrieval and learning:**
On a query, inspect confirmed local durable memories and the permitted
semantic index. If a source is remote and networking is allowed, retrieve
only the needed encrypted snapshot/chunks, authenticate/decrypt, verify source
IDs and assemble a small contextual excerpt; otherwise report offline
unavailability and continue locally. Sync confirmed claims separately from
candidate claims. Evaluate suggestions against source evidence and tests
before promotion. This improves retrieval/procedure; it does not train the
LLM's neural weights by itself.

## Deletion, consistency, privacy

- Do not merge live SQLite database files from different devices. Exchange
  immutable encrypted objects and versioned metadata/events instead.
- Manage concurrent updates with stable global IDs, revisions and explicit
  conflict resolution. Never let last-write-wins silently remove messages.
- Deleting a chat or forgetting a memory must propagate an authenticated
  tombstone to authorized peers when they reconnect; maintain an offline
  pending-deletion journal. Old backups must not silently reintroduce erased
  memories. Specify retention for physically offline copies.
- Memory/chat ACLs and isolation are scoped to user/project; index lookup does
  not grant automatic authorization to retrieve another project's data.
- Sensitive data remains opt-in. A shared archive must not become a route for
  exposing personal material to remote model providers without explicit intent.

Validation: source/CI is not physical acceptance. Keep #902's S24 acceptance
sequence and existing 1.0.15 OTA distribution separate.
