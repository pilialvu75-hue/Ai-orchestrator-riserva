// Cloudflare D1 adapter for the Web-only approved_execution_reservation contract.
// SOURCE-ONLY. This file is not imported by any Pages Function or production UI.
// A future authenticated Web endpoint must create the trusted approval records.
// No user-controlled "approved" field may be written into the approval table.

const READ_APPROVAL = `
SELECT product, owner_subject AS ownerSubject, project_id AS projectId,
       status, current_revision AS currentRevision,
       approved_revision AS approvedRevision,
       approved_spec_sha256 AS approvedSpecSha256,
       approval_id AS approvalId
FROM web_project_approvals
WHERE owner_subject = ?1 AND project_id = ?2
`;

const INSERT_RESERVATION = `
INSERT OR IGNORE INTO web_execution_reservations
(idempotency_key, product, owner_subject, project_id, revision,
 approval_id, approved_spec_sha256, execution_id, attempt_id,
 status, artifact_sha256, created_at)
SELECT ?1, 'aivexus-web', p.owner_subject, p.project_id, p.current_revision,
       p.approval_id, p.approved_spec_sha256, ?6, ?7,
       'reserved', NULL, ?8
FROM web_project_approvals AS p
WHERE p.owner_subject = ?2 AND p.project_id = ?3
  AND p.product = 'aivexus-web' AND p.status = 'approved'
  AND p.current_revision = ?4 AND p.approved_revision = ?4
  AND p.approved_spec_sha256 = ?5
  AND p.approval_id = ?9
`;

const READ_RESERVATION = `
SELECT idempotency_key AS idempotencyKey,
       owner_subject AS ownerSubject, project_id AS projectId,
       revision, approval_id AS approvalId,
       approved_spec_sha256 AS approvedSpecSha256,
       execution_id AS executionId, attempt_id AS attemptId,
       status, artifact_sha256 AS artifactSha256,
       created_at AS createdAt
FROM web_execution_reservations WHERE idempotency_key = ?1
`;

/**
 * Requires a D1-compatible database with prepare().bind().first()/run().
 * Uses one INSERT...SELECT statement to check the latest trusted approval
 * while reserving the unique key. No read-then-write race for authorization.
 * D1's changes count is NOT used to decide created: a separate SELECT is
 * required and duplicate requests return the same receipt.
 */
export function createWebD1ReservationStore(db) {
  if (!db || typeof db.prepare !== 'function') {
    throw new TypeError('D1 binding required');
  }
  return Object.freeze({
    async readApprovedProject({ ownerSubject, projectId }) {
      return await db.prepare(READ_APPROVAL)
        .bind(ownerSubject, projectId).first();
    },
    async reserveOnce({ key, intended }) {
      // D1 run() returns a count for the actual inserted row. A non-atomic
      // "SELECT then INSERT" is forbidden; INSERT OR IGNORE is the gate.
      const result = await db.prepare(INSERT_RESERVATION)
        .bind(key, intended.ownerSubject, intended.projectId,
          intended.revision, intended.approvedSpecSha256,
          intended.executionId, intended.attemptId, intended.createdAt,
          intended.approvalId).run();
      const record = await db.prepare(READ_RESERVATION).bind(key).first();
      if (!record) return { created: false, record: null };
      const created = Number(result?.meta?.changes) === 1;
      return { created, record };
    },
  });
}
