import test from 'node:test';
import assert from 'node:assert/strict';
import { reserveApprovedWebExecution as reserve } from '../../scripts/web/approved_execution_reservation.mjs';

const subject = 'verified-access-user-1';
const projectId = 'counter-1';
const firstHash = 'a'.repeat(64);

function approved(ownerSubject = subject, currentRevision = 1, hash = firstHash) {
  return {
    product: 'aivexus-web',
    ownerSubject,
    projectId,
    status: 'approved',
    currentRevision,
    approvedRevision: currentRevision,
    approvedSpecSha256: hash,
    approvalId: 'approval-' + currentRevision,
  };
}

function fixture(initialApproval = approved()) {
  const approvals = new Map();
  if (initialApproval) {
    approvals.set(initialApproval.ownerSubject + ':' + projectId, initialApproval);
  }
  const rows = new Map();
  let createdCount = 0;
  const store = {
    async readApprovedProject({ownerSubject, projectId: p}) {
      return approvals.get(ownerSubject + ':' + p) ?? null;
    },
    async reserveOnce({key, intended}) {
      // Emulates an atomic UNIQUE(key) insert: no await between read and write.
      if (rows.has(key)) return {created: false, record: rows.get(key)};
      rows.set(key, structuredClone(intended));
      createdCount++;
      return {created: true, record: rows.get(key)};
    },
  };
  const run = (request = {projectId}, owner = subject) => reserve({
    request,
    principal: {subject: owner},
    store,
  });
  return {store, run, approvals, rows, get createdCount() {return createdCount;}};
}

test('trusted approved revision reserves once; never claims build completion', async () => {
  const f = fixture();
  const first = await f.run();
  const again = await f.run();
  assert.equal(first.ok, true);
  assert.equal(first.created, true);
  assert.equal(first.status, 'reserved');
  assert.equal(first.artifactSha256, undefined);
  assert.equal(again.ok, true);
  assert.equal(again.created, false);
  assert.equal(again.executionId, first.executionId);
  assert.equal(again.attemptId, first.attemptId);
  assert.equal(f.createdCount, 1);
  assert.doesNotMatch(JSON.stringify(first), /ownerSubject|verified-access-user-1/);
});

test('25 simultaneous requests reserve exactly one durable attempt', async () => {
  const f = fixture();
  const responses = await Promise.all(Array.from({length: 25}, () => f.run()));
  assert.equal(responses.filter(r => r.created).length, 1);
  assert.equal(f.createdCount, 1);
  assert.equal(new Set(responses.map(r => r.executionId)).size, 1);
  assert.equal(new Set(responses.map(r => r.attemptId)).size, 1);
});

test('browser approval and specification fields cannot grant execution', async () => {
  const f = fixture(null);
  for (const request of [
    {projectId, approved: true},
    {projectId, approvedRevision: 1},
    {projectId, approvedSpecSha256: firstHash},
    {projectId, ownerSubject: subject},
    {projectId, apiKey: 'fake'},
    {projectId: '../other'},
  ]) {
    const response = await f.run(request);
    assert.deepEqual(response, {ok: false, reason: 'invalid_request'});
  }
  assert.equal((await f.run()).reason, 'approval_required');
  assert.equal(f.createdCount, 0);
});

test('stale, rejected or foreign approval fails closed', async () => {
  const f = fixture();
  f.approvals.set(subject + ':' + projectId, {...approved(), approvedRevision: 0});
  assert.equal((await f.run()).reason, 'approval_required');
  f.approvals.set(subject + ':' + projectId, {...approved(), status: 'rejected'});
  assert.equal((await f.run()).reason, 'approval_required');
  f.approvals.set(subject + ':' + projectId, approved('another-owner'));
  assert.equal((await f.run()).reason, 'approval_required');
  assert.equal((await f.run({projectId}, 'another-owner')).reason, 'approval_required');
  assert.equal(f.createdCount, 0);
});

test('changed approved revision is new reservation; old receipt remains', async () => {
  const f = fixture();
  const old = await f.run();
  f.approvals.set(subject + ':' + projectId, approved(subject, 2, 'b'.repeat(64)));
  const newer = await f.run();
  assert.equal(newer.created, true);
  assert.notEqual(newer.executionId, old.executionId);
  assert.equal(f.createdCount, 2);
  assert.equal(f.rows.size, 2);
  const repeated = await f.run();
  assert.equal(repeated.created, false);
  assert.equal(repeated.executionId, newer.executionId);
});

test('reapproval of unchanged revision is not a second execution', async () => {
  const f = fixture();
  const first = await f.run();
  f.approvals.set(subject + ':' + projectId, {...approved(), approvalId: 'reapproval-1'});
  const replay = await f.run();
  assert.equal(replay.created, false);
  assert.equal(replay.executionId, first.executionId);
  assert.equal(f.createdCount, 1);
});

test('storage failure and missing verified identity fail safely', async () => {
  const f = fixture();
  assert.equal((await reserve({request: {projectId}, principal: null, store: f.store})).reason,
    'verified_identity_required');
  assert.equal((await reserve({request: {projectId}, principal: {subject}, store: {}})).reason,
    'storage_unavailable');
  const broken = {...f.store, reserveOnce: async () => {throw new Error('internal: secret');}};
  const response = await reserve({request: {projectId}, principal: {subject}, store: broken});
  assert.deepEqual(response, {ok: false, reason: 'storage_unavailable'});
});

test('inconsistent or non-atomic store responses are not accepted', async () => {
  const f = fixture();
  const broken = {...f.store, reserveOnce: async () => ({
    created: true, record: {...approved(), status: 'completed', executionId: 'fake'},
  })};
  const response = await reserve({request: {projectId}, principal: {subject}, store: broken});
  assert.deepEqual(response, {ok: false, reason: 'storage_inconsistent'});
});
