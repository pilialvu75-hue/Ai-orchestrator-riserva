// Web-owned D1 proposal staging, approval and revocation.
// Call only after verifying the Access JWT in the HTTP operation gate.
// Apply migrations 001 and 002 before using this module.

const PROJECT_ID = /^[a-z0-9][a-z0-9._:-]{0,127}$/i;
const SHA256 = /^[0-9a-f]{64}$/;
const APPROVAL_ID = /^web-approval-[0-9a-f-]{36}$/;
const COUNTER_SPEC = 'original-counter-specification-v1';

const STAGE_COUNTER_SQL = `
INSERT INTO web_project_approvals
(owner_subject, project_id, product, status, current_revision, updated_at, proposal_spec_sha256)
VALUES (?1, ?2, 'aivexus-web', 'proposal_ready', 1, ?3, ?4)
ON CONFLICT(owner_subject, project_id) DO NOTHING
`;

const READ_COUNTER_PROPOSAL_SQL = `
SELECT status, current_revision AS revision, proposal_spec_sha256 AS specSha256
FROM web_project_approvals
WHERE owner_subject = ?1 AND project_id = ?2 AND product = 'aivexus-web'
`;

// UPDATE is a single atomic compare-and-swap of owner, revision, proposal
// digest and state. Browser-provided digest is a precondition, not the value
// written as approved_spec_sha256: the database copies its own trusted digest.
const APPROVE_SQL = `
UPDATE web_project_approvals
SET status = 'approved', approved_revision = current_revision,
    approved_spec_sha256 = proposal_spec_sha256,
    approval_id = ?5, updated_at = ?6
WHERE owner_subject = ?1 AND project_id = ?2 AND product = 'aivexus-web'
  AND status = 'proposal_ready'
  AND current_revision = ?3
  AND proposal_spec_sha256 = ?4
  AND length(proposal_spec_sha256) = 64
  AND approved_revision IS NULL AND approved_spec_sha256 IS NULL
  AND approval_id IS NULL
`;

const REVOKE_SQL = `
UPDATE web_project_approvals
SET status = 'revoked', approved_revision = NULL,
    approved_spec_sha256 = NULL, approval_id = NULL, updated_at = ?5
WHERE owner_subject = ?1 AND project_id = ?2 AND product = 'aivexus-web'
  AND status = 'approved' AND current_revision = ?3
  AND approval_id = ?4
`;

function fail(reason) {
  return { ok: false, reason };
}
function hasExactKeys(o, expected) {
  return !!o && typeof o === 'object' && !Array.isArray(o) &&
    Object.keys(o).length === expected.length &&
    expected.every(key => Object.prototype.hasOwnProperty.call(o, key));
}
function validProject(p) {
  return typeof p === 'string' && PROJECT_ID.test(p);
}
function validRevision(rev) {
  return Number.isSafeInteger(rev) && rev > 0;
}
function verifiedSubject(principal) {
  // The trusted server adapter creates this object only after JWT validation.
  // This tag is a contract marker, not independent cryptographic validation.
  if (principal?.verifiedBy !== 'cloudflare-access-jwt') return null;
  const subject = principal.subject;
  if (typeof subject !== 'string' || !subject.trim() ||
      subject.length > 256) return null;
  return subject;
}
async function update(db, sql, params) {
  try {
    const result = await db.prepare(sql).bind(...params).run();
    if (result?.success === false || !Number.isInteger(result?.meta?.changes)) {
      return fail('storage_unavailable');
    }
    return result.meta.changes === 1 ? { ok: true } :
      result.meta.changes === 0 ? fail('stale_or_not_ready') :
      fail('storage_inconsistent');
  } catch (_) {
    // Never emit D1 errors, SQL or credentials into browser responses.
    return fail('storage_unavailable');
  }
}
function preflight(principal, db) {
  const subject = verifiedSubject(principal);
  if (!subject) return fail('verified_identity_required');
  if (!db || typeof db.prepare !== 'function') {
    return fail('storage_unavailable');
  }
  return { ok: true, subject };
}

export async function webCounterSpecSha256() {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(COUNTER_SPEC));
  return Array.from(new Uint8Array(digest), byte =>
    byte.toString(16).padStart(2, '0')).join('');
}

export async function stageTrustedWebCounterProposal({ request, principal, db } = {}) {
  const ctx = preflight(principal, db);
  if (!ctx.ok) return ctx;
  if (!hasExactKeys(request, ['projectId']) || !validProject(request.projectId)) {
    return fail('invalid_request');
  }

  const { projectId } = request;
  const specSha256 = await webCounterSpecSha256();
  try {
    const result = await db.prepare(STAGE_COUNTER_SQL)
      .bind(ctx.subject, projectId, new Date().toISOString(), specSha256).run();
    if (result?.success !== true || ![0, 1].includes(result.meta?.changes)) {
      return fail('storage_unavailable');
    }
    const proposal = await db.prepare(READ_COUNTER_PROPOSAL_SQL)
      .bind(ctx.subject, projectId).first();
    if (proposal?.revision !== 1 || proposal.specSha256 !== specSha256 ||
        !['proposal_ready', 'approved'].includes(proposal.status)) {
      return fail('stale_or_not_ready');
    }
    return { ok: true, projectId, revision: 1, specSha256, status: proposal.status };
  } catch (_) {
    return fail('storage_unavailable');
  }
}

export async function approveTrustedWebProposal({ request, principal, db } = {}) {
  const ctx = preflight(principal, db);
  if (!ctx.ok) return ctx;
  if (!hasExactKeys(request, ['projectId', 'expectedRevision', 'expectedSpecSha256']) ||
      !validProject(request.projectId) ||
      !validRevision(request.expectedRevision) ||
      typeof request.expectedSpecSha256 !== 'string' ||
      !SHA256.test(request.expectedSpecSha256)) {
    return fail('invalid_request');
  }
  // Do not accept approval IDs, subjects or persisted proposal digests as
  // browser-controlled values. The generated ID is only a server-side nonce.
  const approvalId = 'web-approval-' + crypto.randomUUID();
  const result = await update(db, APPROVE_SQL, [
    ctx.subject, request.projectId, request.expectedRevision,
    request.expectedSpecSha256, approvalId, new Date().toISOString(),
  ]);
  if (!result.ok) return result;
  return {
    ok: true, projectId: request.projectId,
    approvedRevision: request.expectedRevision, approvalId,
    // Approval is NOT a build, test, artifact or execution reservation.
  };
}

export async function revokeTrustedWebApproval({ request, principal, db } = {}) {
  const ctx = preflight(principal, db);
  if (!ctx.ok) return ctx;
  if (!hasExactKeys(request, ['projectId', 'expectedRevision', 'approvalId']) ||
      !validProject(request.projectId) ||
      !validRevision(request.expectedRevision) ||
      typeof request.approvalId !== 'string' ||
      !APPROVAL_ID.test(request.approvalId)) {
    return fail('invalid_request');
  }
  const result = await update(db, REVOKE_SQL, [
    ctx.subject, request.projectId, request.expectedRevision,
    request.approvalId, new Date().toISOString(),
  ]);
  if (!result.ok) return result;
  return { ok: true, projectId: request.projectId, status: 'revoked' };
}

// IMPORTANT: Revoking an approval blocks NEW reservations through the existing
// INSERT...SELECT gate. A future job runner MUST also revalidate the approval
// immediately before any reserved job side effects, and reconcile cancellations.
