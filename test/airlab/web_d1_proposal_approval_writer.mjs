import test from 'node:test';
import assert from 'node:assert/strict';
import {
  approveTrustedWebProposal as approve,
  revokeTrustedWebApproval as revoke,
} from '../../scripts/web/d1_web_proposal_approval_writer.mjs';

const subject = 'verified-owner-1';
const projectId = 'web-counter';
const digest = 'a'.repeat(64);
const principal = { subject, verifiedBy: 'cloudflare-access-jwt' };
const request = { projectId, expectedRevision: 3, expectedSpecSha256: digest };

function fixture() {
  const row = {
    owner: subject, projectId, status: 'proposal_ready',
    currentRevision: 3, proposalSpecSha256: digest,
    approvedRevision: null, approvedSpecSha256: null, approvalId: null,
  };
  let approvals = 0;
  let revocations = 0;
  const db = {
    prepare(sql) {
      return {
        bind(...args) {
          return {
            async run() {
              assert.match(sql, /UPDATE web_project_approvals/);
              assert.match(sql, /owner_subject = \?1 AND project_id = \?2/);
              let changed = 0;
              if (sql.includes("SET status = 'approved'")) {
                const [owner, id, revision, hash, approvalId] = args;
                assert.match(sql, /approved_spec_sha256 = proposal_spec_sha256/);
                if (owner === row.owner && id === row.projectId &&
                    row.status === 'proposal_ready' &&
                    revision === row.currentRevision &&
                    hash === row.proposalSpecSha256 &&
                    row.approvedRevision === null && row.approvalId === null) {
                  row.status = 'approved'; row.approvedRevision = revision;
                  row.approvedSpecSha256 = row.proposalSpecSha256;
                  row.approvalId = approvalId;
                  approvals++; changed = 1;
                }
              } else if (sql.includes("SET status = 'revoked'")) {
                const [owner, id, revision, approvalId] = args;
                if (owner === row.owner && id === row.projectId &&
                    row.status === 'approved' &&
                    revision === row.currentRevision &&
                    approvalId === row.approvalId) {
                  row.status = 'revoked'; row.approvedRevision = null;
                  row.approvedSpecSha256 = null; row.approvalId = null;
                  revocations++; changed = 1;
                }
              } else throw new Error('unexpected SQL');
              return { success: true, meta: { changes: changed } };
            },
          };
        },
      };
    },
  };
  return { db, row, get approvals() { return approvals; },
    get revocations() { return revocations; } };
}

test('trusted proposal approves exactly its existing digest', async () => {
  const f = fixture();
  const response = await approve({ request, principal, db: f.db });
  assert.equal(response.ok, true);
  assert.match(response.approvalId, /^web-approval-/);
  assert.equal(f.approvals, 1);
  assert.equal(f.row.approvedSpecSha256, digest);
  assert.equal(f.row.approvalId, response.approvalId);
  assert.doesNotMatch(JSON.stringify(response), /verified-owner|approvedSpecSha256/);
  assert.equal((await approve({ request, principal, db: f.db })).reason,
    'stale_or_not_ready');
});

test('25 simultaneous approvals change the row only once', async () => {
  const f = fixture();
  const responses = await Promise.all(Array.from({ length: 25 }, () =>
    approve({ request, principal, db: f.db })));
  assert.equal(responses.filter(r => r.ok).length, 1);
  assert.equal(f.approvals, 1);
});

test('owner, revision and proposal digest are immutable CAS preconditions', async () => {
  const f = fixture();
  for (const [req, who] of [
    [request, { subject: 'other-owner', verifiedBy: 'cloudflare-access-jwt' }],
    [{ ...request, expectedRevision: 2 }, principal],
    [{ ...request, expectedSpecSha256: 'b'.repeat(64) }, principal],
  ]) {
    assert.equal((await approve({ request: req, principal: who, db: f.db }))
      .reason, 'stale_or_not_ready');
  }
  assert.equal(f.approvals, 0);
});

test('browser forgery and missing JWT-verified principal fail closed', async () => {
  const f = fixture();
  for (const req of [
    { ...request, approved: true },
    { ...request, ownerSubject: subject },
    { ...request, approvalId: 'browser-picked' },
    { ...request, expectedRevision: '3' },
    { ...request, expectedSpecSha256: '../secret' },
    { ...request, projectId: '../other' },
  ]) {
    assert.equal((await approve({ request: req, principal, db: f.db }))
      .reason, 'invalid_request');
  }
  for (const who of [null, { subject },
    { subject, verifiedBy: 'browser-claimed' }]) {
    assert.equal((await approve({ request, principal: who, db: f.db }))
      .reason, 'verified_identity_required');
  }
  assert.equal(f.approvals, 0);
});

test('revoke requires current owner, approval ID and revision; replay fails', async () => {
  const f = fixture();
  const a = await approve({ request, principal, db: f.db });
  const revokeRequest = {
    projectId, expectedRevision: 3, approvalId: a.approvalId,
  };
  assert.equal((await revoke({ request: { ...revokeRequest, expectedRevision: 2 },
    principal, db: f.db })).reason, 'stale_or_not_ready');
  assert.equal((await revoke({ request: { ...revokeRequest, approvalId:
    'web-approval-' + 'a'.repeat(36) }, principal, db: f.db }))
    .reason, 'stale_or_not_ready');
  const r = await revoke({ request: revokeRequest, principal, db: f.db });
  assert.deepEqual(r, { ok: true, projectId, status: 'revoked' });
  assert.equal(f.revocations, 1);
  assert.equal(f.row.approvalId, null);
  assert.equal((await revoke({ request: revokeRequest, principal, db: f.db }))
    .reason, 'stale_or_not_ready');
  assert.equal((await approve({ request, principal, db: f.db })).reason,
    'stale_or_not_ready');
});

test('DB exceptions and malformed results never leak SQL or credentials', async () => {
  const broken = {
    prepare() {
      throw new Error('private SQL and secret');
    },
  };
  assert.deepEqual(await approve({ request, principal, db: broken }),
    { ok: false, reason: 'storage_unavailable' });
  assert.equal((await approve({ request, principal, db: null })).reason,
    'storage_unavailable');
  assert.equal((await approve({ request, principal, db: {
    prepare: () => ({ bind: () => ({ run: async () => ({
      success: false, meta: { changes: 1 },
    }) }) }),
  } })).reason, 'storage_unavailable');
});
