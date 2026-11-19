import { createWebD1ExecutionJournal } from './d1_execution_journal_store.mjs';
import {
  createD1WebCounterArtifactStore, MAX_COUNTER_D1_ZIP_BYTES,
} from './d1_web_counter_artifact_store.mjs';
import { webCounterSpecSha256 } from './d1_web_proposal_approval_writer.mjs';
import {
  MAX_ARTIFACT_BYTES, readVerifiedWebZip, webZipSha256,
} from './web_execution_artifact_download.mjs';

const READ_COUNTER_ATTEMPT = `
SELECT execution_id AS executionId, approved_spec_sha256 AS specSha256
FROM web_execution_reservations
WHERE idempotency_key = ?1 AND attempt_id = ?2 AND product = 'aivexus-web'
  AND status = 'reserved'
`;

// Internal scope only. buildAndTestCounter is a trusted isolated runner that
// resolves to the ZIP bytes after the fixed counter's build and tests pass.
export async function runWebCounterAttempt({ db, bucket, key, attemptId, buildAndTestCounter }) {
  const store = bucket ?? createD1WebCounterArtifactStore(db);
  const maxBytes = bucket == null ? MAX_COUNTER_D1_ZIP_BYTES : MAX_ARTIFACT_BYTES;
  if (typeof db?.prepare !== 'function' || typeof store.get !== 'function' ||
      typeof store.put !== 'function' || typeof buildAndTestCounter !== 'function') {
    return { ok: false, reason: 'runner_unavailable' };
  }
  let execution;
  try {
    execution = await db.prepare(READ_COUNTER_ATTEMPT).bind(key, attemptId).first();
    if (!execution || execution.specSha256 !== await webCounterSpecSha256() ||
        !/^web-exec-[0-9a-f]{32}$/.test(execution.executionId)) {
      return { ok: false, reason: 'counter_attempt_unavailable' };
    }
  } catch (_) {
    return { ok: false, reason: 'storage_unavailable' };
  }

  const journal = createWebD1ExecutionJournal(db);
  const attempt = { key, attemptId, workerToken: crypto.randomUUID() };
  const claim = await journal.claimReserved(attempt);
  if (!claim.ok) return claim;

  let zip;
  try {
    zip = await buildAndTestCounter();
    if (!(zip instanceof Uint8Array) || zip.byteLength === 0 ||
        zip.byteLength > maxBytes) {
      throw new Error('Invalid ZIP byte count');
    }
  } catch (_) {
    const failure = await journal.failAttempt({ ...attempt, failureKind: 'build' });
    return { ok: false, reason: failure.ok ? 'build_failed' : 'outcome_unverified' };
  }

  try {
    const sha256 = await webZipSha256(zip);
    const storageKey = `web-artifacts/${execution.executionId}/${sha256}.zip`;
    const put = await store.put(storageKey, zip, {
      onlyIf: new Headers({ 'If-None-Match': '*' }),
      httpMetadata: { contentType: 'application/zip' },
    });
    const readback = put && await readVerifiedWebZip({
      bucket: store, storageKey, size: zip.byteLength, sha256,
    });
    if (readback) {
      const completed = await journal.completeVerifiedArtifact({
        ...attempt, artifactSha256: sha256, artifactSizeBytes: zip.byteLength,
        storageReadbackVerified: true, testsPassed: true,
      });
      if (completed.ok) return { ok: true, executionId: execution.executionId };
    }
  } catch (_) {
    // A failed reply can be ambiguous after an object write or a D1 update.
  }
  const review = await journal.flagInterruptedForReview(attempt);
  return { ok: false, reason: review.ok ? 'review_required' : 'outcome_unverified' };
}
