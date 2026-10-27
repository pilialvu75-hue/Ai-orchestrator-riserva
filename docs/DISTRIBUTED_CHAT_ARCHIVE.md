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
