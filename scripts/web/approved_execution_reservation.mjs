// SOURCE-ONLY contract for Aivexus Web. No route, provider call, or worker is wired.
// The future HTTP adapter MUST obtain principal from verified Cloudflare Access
// and approval from a Web-owned durable server store, never from request JSON.
// The production store MUST atomically reserveOnce via a unique idempotency key.

const PROJECT_ID = /^[a-z0-9][a-z0-9._:-]{0,127}$/i;
const APPROVAL_ID = /^[a-z0-9][a-z0-9._:-]{0,127}$/i;
const SHA256 = /^[0-9a-f]{64}$/;
const STATES = new Set(['reserved', 'running', 'review_required', 'failed', 'completed']);

function failure(reason) {
  return { ok: false, reason };
}

async function sha256Hex(text) {
  const data = new TextEncoder().encode(text);
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', data));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function validApproval(value, subject, projectId) {
  return value &&
    value.product === 'aivexus-web' &&
    value.ownerSubject === subject &&
    value.projectId === projectId &&
    value.status === 'approved' &&
    Number.isSafeInteger(value.currentRevision) &&
    value.currentRevision > 0 &&
    value.approvedRevision === value.currentRevision &&
    typeof value.approvedSpecSha256 === 'string' &&
    SHA256.test(value.approvedSpecSha256) &&
    typeof value.approvalId === 'string' &&
    APPROVAL_ID.test(value.approvalId);
}

// No side effects are executed: only a durable, single-use reservation is made.
// The returned record is a sanitized view, not proof that build or tests ran.
export async function reserveApprovedWebExecution({ request, principal, store } = {}) {
  if (!principal || typeof principal.subject !== 'string' ||
      !principal.subject.trim() || principal.subject.length > 256) {
    return failure('verified_identity_required');
  }
  if (!request || typeof request !== 'object' || Array.isArray(request) ||
      Object.keys(request).length !== 1 ||
      !Object.prototype.hasOwnProperty.call(request, 'projectId') ||
      typeof request.projectId !== 'string' ||
      !PROJECT_ID.test(request.projectId)) {
    // Reject approved=true, revision, spec, model, token or owner from browser.
    return failure('invalid_request');
  }
  if (!store || typeof store.readApprovedProject !== 'function' ||
      typeof store.reserveOnce !== 'function') {
    return failure('storage_unavailable');
  }

  const subject = principal.subject;
  const projectId = request.projectId;
  let approval;
  try {
    approval = await store.readApprovedProject({ ownerSubject: subject, projectId });
  } catch (_) {
    return failure('storage_unavailable');
  }
  if (!validApproval(approval, subject, projectId)) {
    return failure('approval_required');
  }

  // Exclude approvalId to ensure reapproval of an unchanged revision does not
  // cause a second execution. A revised approved specification gets a new key.
  const key = await sha256Hex(JSON.stringify([
    'aivexus-web-execution-v1', subject, projectId,
    approval.currentRevision, approval.approvedSpecSha256,
  ]));
  const intended = {
    schemaVersion: 1,
    product: 'aivexus-web',
    ownerSubject: subject,
    projectId,
    revision: approval.currentRevision,
    approvalId: approval.approvalId,
    approvedSpecSha256: approval.approvedSpecSha256,
    idempotencyKey: key,
    executionId: 'web-exec-' + key.slice(0, 32),
    attemptId: crypto.randomUUID(),
    status: 'reserved',
    artifactSha256: null,
    createdAt: new Date().toISOString(),
  };

  let reservation;
  try {
    // This is a REQUIRED atomic insert-if-absent operation of the future store.
    // Never implement it as an unguarded read followed by a separate write.
    reservation = await store.reserveOnce({ key, intended });
  } catch (_) {
    return failure('storage_unavailable');
  }
  const record = reservation?.record;
  if (typeof reservation?.created !== 'boolean' ||
      !record || record.idempotencyKey !== key ||
      record.ownerSubject !== subject || record.projectId !== projectId ||
      record.revision !== approval.currentRevision ||
      record.approvedSpecSha256 !== approval.approvedSpecSha256 ||
      typeof record.executionId !== 'string' ||
      typeof record.attemptId !== 'string' || !STATES.has(record.status)) {
    return failure('storage_inconsistent');
  }
  return {
    ok: true,
    created: reservation.created,
    status: record.status,
    executionId: record.executionId,
    attemptId: record.attemptId,
    approvedRevision: record.revision,
    // No claim of successful build, no secret, no owner identity, no provider.
  };
}
