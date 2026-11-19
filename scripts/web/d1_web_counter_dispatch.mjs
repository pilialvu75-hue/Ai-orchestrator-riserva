import { webCounterSpecSha256 } from './d1_web_proposal_approval_writer.mjs';

const EXECUTION_ID = /^web-exec-[0-9a-f]{32}$/;
const SHA = /^[0-9a-f]{40}$/;

const CLAIM_DISPATCH = `
INSERT INTO web_counter_dispatch (execution_id, ticket, head_sha, state)
SELECT e.execution_id, ?3, ?4, 'dispatching'
FROM web_execution_reservations AS e
JOIN web_project_approvals AS a
  ON a.owner_subject = e.owner_subject AND a.project_id = e.project_id
WHERE e.execution_id = ?1 AND e.owner_subject = ?2 AND e.product = 'aivexus-web'
  AND e.status = 'reserved' AND e.approved_spec_sha256 = ?5
  AND a.product = e.product AND a.status = 'approved'
  AND a.current_revision = e.revision AND a.approved_revision = e.revision
  AND a.approved_spec_sha256 = e.approved_spec_sha256 AND a.approval_id = e.approval_id
ON CONFLICT(execution_id) DO NOTHING
`;

export async function readWebCounterDispatch({ db, ownerSubject, executionId }) {
  return await db.prepare(`
    SELECT d.ticket, d.head_sha AS headSha, d.state, d.github_run_id AS runId,
           e.idempotency_key AS executionKey, e.attempt_id AS attemptId
    FROM web_counter_dispatch AS d
    JOIN web_execution_reservations AS e ON e.execution_id = d.execution_id
    WHERE d.execution_id = ?1 AND e.owner_subject = ?2 AND e.product = 'aivexus-web'
  `).bind(executionId, ownerSubject).first();
}

// Use only with the subject from a verified Access JWT. The ticket and GitHub
// run identity are internal and must stay out of browser responses.
export async function dispatchReservedWebCounter({
  db, github, ownerSubject, executionId, expectedHeadSha, publicKeySpki,
}) {
  if (typeof db?.prepare !== 'function' || typeof github?.dispatch !== 'function' ||
      typeof ownerSubject !== 'string' || !ownerSubject ||
      typeof executionId !== 'string' || !EXECUTION_ID.test(executionId) ||
      typeof expectedHeadSha !== 'string' || !SHA.test(expectedHeadSha) ||
      typeof publicKeySpki !== 'string' || !publicKeySpki.length ||
      publicKeySpki.length > 416 || !/^[A-Za-z0-9+/]+={0,2}$/.test(publicKeySpki)) {
    throw new TypeError('Counter dispatch configuration is invalid');
  }
  const ticket = crypto.randomUUID();
  const claim = await db.prepare(CLAIM_DISPATCH)
    .bind(executionId, ownerSubject, ticket, expectedHeadSha, await webCounterSpecSha256())
    .run();
  if (!claim?.success || ![0, 1].includes(claim.meta?.changes)) {
    throw new Error('Counter dispatch claim unavailable');
  }
  if (claim.meta.changes === 0) {
    const existing = await readWebCounterDispatch({ db, ownerSubject, executionId });
    return { state: existing?.state ?? 'not_found' };
  }

  let runId;
  try {
    runId = await github.dispatch({ ticket, publicKeySpki });
    if (!Number.isSafeInteger(runId) || runId <= 0) throw new Error('Invalid workflow run ID');
  } catch (_) {
    const changed = await db.prepare(`
      UPDATE web_counter_dispatch SET state = 'review_required'
      WHERE execution_id = ?1 AND ticket = ?2 AND state = 'dispatching'
    `).bind(executionId, ticket).run();
    if (!changed?.success || changed.meta?.changes !== 1) {
      throw new Error('Counter dispatch outcome unavailable');
    }
    return { state: 'review_required' };
  }
  const submitted = await db.prepare(`
    UPDATE web_counter_dispatch SET state = 'submitted', github_run_id = ?3
    WHERE execution_id = ?1 AND ticket = ?2 AND state = 'dispatching'
  `).bind(executionId, ticket, runId).run();
  if (!submitted?.success || submitted.meta?.changes !== 1) {
    // The workflow may exist. The persisted claim still prevents a second POST.
    throw new Error('Counter dispatch outcome unavailable');
  }
  return { state: 'submitted' };
}
