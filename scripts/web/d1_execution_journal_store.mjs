// SOURCE-ONLY D1 execution journal adapter for Aivexus Web.
// NOT imported by Pages Functions or an active worker. No D1 binding or
// Cloudflare resource is created here. This is a trusted server-side worker
// contract, NEVER a browser/HTTP API. No auto-retry after claiming a run.
// Apply SQL migrations 001, 002, 003 before using this adapter.

const KEY = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256 = /^[0-9a-f]{64}$/;
const MAX_ARTIFACT_BYTES = 16 * 1024 * 1024; // bounded zero-cost counter MVP
const FAILURES = new Set(['build', 'test', 'storage', 'reconciliation']);

const CLAIM_SQL = `
UPDATE web_execution_reservations
SET status = 'running', worker_token = ?3,
    journal_version = journal_version + 1, transition_at = ?4
WHERE idempotency_key = ?1 AND attempt_id = ?2
  AND product = 'aivexus-web' AND status = 'reserved'
  AND worker_token IS NULL
  AND EXISTS (
    SELECT 1 FROM web_project_approvals AS p
    WHERE p.owner_subject = web_execution_reservations.owner_subject
      AND p.project_id = web_execution_reservations.project_id
      AND p.product = 'aivexus-web' AND p.status = 'approved'
      AND p.current_revision = web_execution_reservations.revision
      AND p.approved_revision = web_execution_reservations.revision
      AND p.approved_spec_sha256 =
        web_execution_reservations.approved_spec_sha256
      AND p.approval_id = web_execution_reservations.approval_id
  )
`;

const COMPLETE_SQL = `
UPDATE web_execution_reservations
SET status = 'completed', artifact_sha256 = ?4,
    artifact_storage_key =
      'web-artifacts/' || execution_id || '/' || ?4 || '.zip',
    artifact_size_bytes = ?5, journal_version = journal_version + 1,
    transition_at = ?6
WHERE idempotency_key = ?1 AND attempt_id = ?2
  AND worker_token = ?3 AND status = 'running'
  AND artifact_sha256 IS NULL
  AND EXISTS (
    SELECT 1 FROM web_project_approvals AS p
    WHERE p.owner_subject = web_execution_reservations.owner_subject
      AND p.project_id = web_execution_reservations.project_id
      AND p.product = 'aivexus-web' AND p.status = 'approved'
      AND p.current_revision = web_execution_reservations.revision
      AND p.approved_revision = web_execution_reservations.revision
      AND p.approved_spec_sha256 =
        web_execution_reservations.approved_spec_sha256
      AND p.approval_id = web_execution_reservations.approval_id
  )
`;

const FLAG_INTERRUPTED_SQL = `
UPDATE web_execution_reservations
SET status = 'review_required', failure_kind = 'interrupted',
    journal_version = journal_version + 1, transition_at = ?4
WHERE idempotency_key = ?1 AND attempt_id = ?2
  AND worker_token = ?3 AND status = 'running'
`;

const FAIL_SQL = `
UPDATE web_execution_reservations
SET status = 'failed', failure_kind = ?4,
    journal_version = journal_version + 1, transition_at = ?5
WHERE idempotency_key = ?1 AND attempt_id = ?2
  AND worker_token = ?3
  AND (
    (status = 'running' AND ?4 IN ('build','test','storage')) OR
    (status = 'review_required' AND ?4 = 'reconciliation')
  )
`;

const FAIL_PREFLIGHT_SQL = `
UPDATE web_execution_reservations
SET status = 'failed', failure_kind = 'preflight',
    journal_version = journal_version + 1, transition_at = ?3
WHERE idempotency_key = ?1 AND attempt_id = ?2
  AND status = 'reserved' AND worker_token IS NULL
`;

const READ_RECEIPT_SQL = `
SELECT r.execution_id AS executionId, r.attempt_id AS attemptId,
       r.approved_spec_sha256 AS approvedSpecSha256,
       r.artifact_sha256 AS artifactSha256,
       r.artifact_storage_key AS artifactStorageKey,
       r.artifact_size_bytes AS artifactSizeBytes,
       r.recorded_at AS recordedAt
FROM web_execution_artifact_receipts AS r
WHERE r.idempotency_key = ?1
`;

const READ_EVENTS_SQL = `
SELECT journal_version AS journalVersion, from_status AS fromStatus,
       to_status AS toStatus, event_at AS eventAt,
       failure_kind AS failureKind, artifact_sha256 AS artifactSha256
FROM web_execution_journal_events WHERE idempotency_key = ?1
ORDER BY event_id ASC LIMIT 32
`;

function fail(reason) { return { ok: false, reason }; }
function validIds(key, attemptId) {
  return typeof key === 'string' && KEY.test(key) &&
    typeof attemptId === 'string' && UUID.test(attemptId);
}
function validToken(token) {
  return typeof token === 'string' && UUID.test(token);
}

/**
 * All transition methods below are internal to a trusted Web-owned worker.
 * The caller MUST independently verify the stored artifact bytes, SHA256,
 * successful tests and approved revision *before* completeVerifiedArtifact().
 * This adapter cannot access object storage and cannot prove bytes exist.
 */
export function createWebD1ExecutionJournal(db) {
  if (!db || typeof db.prepare !== 'function') {
    throw new TypeError('Web-owned D1 binding required');
  }
  async function change(sql, args) {
    try {
      const result = await db.prepare(sql).bind(...args).run();
      if (result?.success === false || !Number.isInteger(result?.meta?.changes)) {
        return fail('storage_unavailable');
      }
      if (result.meta.changes === 1) return { ok: true, changed: true };
      if (result.meta.changes === 0) return fail('stale_or_not_authorized');
      return fail('storage_inconsistent');
    } catch (_) {
      // SQLite constraint violations, internal SQL and credentials stay private.
      return fail('storage_unavailable');
    }
  }
  async function read(sql, key) {
    if (typeof key !== 'string' || !KEY.test(key)) return fail('invalid_request');
    try {
      return { ok: true, value: await db.prepare(sql).bind(key).first() };
    } catch (_) {
      return fail('storage_unavailable');
    }
  }
  return Object.freeze({
    async claimReserved({ key, attemptId, workerToken }) {
      if (!validIds(key, attemptId) || !validToken(workerToken)) {
        return fail('invalid_request');
      }
      return change(CLAIM_SQL, [key, attemptId, workerToken,
        new Date().toISOString()]);
    },
    async completeVerifiedArtifact({
      key, attemptId, workerToken, artifactSha256, artifactSizeBytes,
      storageReadbackVerified, testsPassed,
    }) {
      // These flags are trusted worker attestations, NOT user-provided values.
      // The actual worker must perform storage read-back and hash validation.
      if (!validIds(key, attemptId) || !validToken(workerToken) ||
          typeof artifactSha256 !== 'string' || !SHA256.test(artifactSha256) ||
          !Number.isSafeInteger(artifactSizeBytes) ||
          artifactSizeBytes <= 0 || artifactSizeBytes > MAX_ARTIFACT_BYTES ||
          storageReadbackVerified !== true || testsPassed !== true) {
        return fail('verified_artifact_required');
      }
      return change(COMPLETE_SQL, [key, attemptId, workerToken,
        artifactSha256, artifactSizeBytes, new Date().toISOString()]);
    },
    async flagInterruptedForReview({ key, attemptId, workerToken }) {
      if (!validIds(key, attemptId) || !validToken(workerToken)) {
        return fail('invalid_request');
      }
      // This is a manual reconciliation marker, NEVER an automatic retry.
      return change(FLAG_INTERRUPTED_SQL, [
        key, attemptId, workerToken, new Date().toISOString(),
      ]);
    },
    async failAttempt({ key, attemptId, workerToken, failureKind }) {
      if (!validIds(key, attemptId) || !validToken(workerToken) ||
          !FAILURES.has(failureKind)) return fail('invalid_request');
      return change(FAIL_SQL, [key, attemptId, workerToken,
        failureKind, new Date().toISOString()]);
    },
    async failPreflight({ key, attemptId }) {
      if (!validIds(key, attemptId)) return fail('invalid_request');
      return change(FAIL_PREFLIGHT_SQL, [key, attemptId,
        new Date().toISOString()]);
    },
    async readImmutableReceipt(key) { return read(READ_RECEIPT_SQL, key); },
    async readJournalEvents(key) {
      if (typeof key !== 'string' || !KEY.test(key)) return fail('invalid_request');
      try {
        const result = await db.prepare(READ_EVENTS_SQL).bind(key).all();
        if (result?.success === false || !Array.isArray(result?.results)) {
          return fail('storage_unavailable');
        }
        return { ok: true, events: result.results };
      } catch (_) { return fail('storage_unavailable'); }
    },
  });
}
