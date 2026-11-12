import test from 'node:test';
import assert from 'node:assert/strict';
import { createWebD1ReservationStore } from '../../scripts/web/d1_approval_reservation_store.mjs';
import { reserveApprovedWebExecution } from '../../scripts/web/approved_execution_reservation.mjs';

const ownerSubject = 'verified-access-actor';
const projectId = 'counter-one';
const hash = 'a'.repeat(64);
const approval = {
  product: 'aivexus-web', ownerSubject, projectId, status: 'approved',
  currentRevision: 1, approvedRevision: 1,
  approvedSpecSha256: hash, approvalId: 'approval-1'
};

function inMemoryD1() {
  const approvals = new Map([[ownerSubject + ':' + projectId, { ...approval }]]);
  const reservations = new Map();
  let inserts = 0;
  const db = {
    prepare(sql) {
      return {
        bind(...values) {
          return {
            async first() {
              if (sql.includes('FROM web_project_approvals') &&
                  !sql.includes('INSERT')) {
                return approvals.get(values[0] + ':' + values[1]) ?? null;
              }
              if (sql.includes('FROM web_execution_reservations')) {
                return reservations.get(values[0]) ?? null;
              }
              throw new Error('Unexpected SELECT');
            },
            async run() {
              assert.match(sql, /INSERT OR IGNORE INTO web_execution_reservations/);
              assert.match(sql, /FROM web_project_approvals AS p/);
              assert.match(sql, /p.status = 'approved'/);
              assert.match(sql, /p.approval_id = \?9/);
              const [key, owner, project, revision, spec, executionId,
                attemptId, createdAt, approvalId] = values;
              const current = approvals.get(owner + ':' + project);
              // Same-statement approval authorization; no async gap.
              if (!current || current.status !== 'approved' ||
                  current.currentRevision !== current.approvedRevision ||
                  current.currentRevision !== revision ||
                  current.approvedSpecSha256 !== spec ||
                  current.approvalId !== approvalId ||
                  reservations.has(key)) return { meta: { changes: 0 } };
              reservations.set(key, {
                idempotencyKey: key, ownerSubject: owner, projectId: project,
                revision, approvedSpecSha256: spec, executionId, attemptId,
                approvalId, status: 'reserved', artifactSha256: null, createdAt
              });
              inserts++;
              return { meta: { changes: 1 } };
            }
          };
        }
      };
    }
  };
  const store = createWebD1ReservationStore(db);
  return {store, approvals, reservations, get inserts() {return inserts;}};
}
function call(state, request = {projectId}) {
  return reserveApprovedWebExecution({
    request, principal: {subject: ownerSubject}, store: state.store
  });
}

test('25 concurrent D1-adapter reservations return one execution and attempt', async () => {
  const state = inMemoryD1();
  const result = await Promise.all(Array.from({length: 25}, () => call(state)));
  assert.equal(result.filter(x=>x.created).length, 1);
  assert.equal(state.inserts, 1);
  assert.equal(new Set(result.map(x=>x.executionId)).size, 1);
  assert.equal(new Set(result.map(x=>x.attemptId)).size, 1);
  assert.equal(result[0].status, 'reserved');
  assert.doesNotMatch(JSON.stringify(result), /verified-access-actor|approvedSpecSha256/);
});

test('revocation between lookup and atomic insert rejects reservation', async () => {
  const state = inMemoryD1();
  const store = {
    async readApprovedProject(args) {
      const value = await state.store.readApprovedProject(args);
      state.approvals.set(ownerSubject + ':' + projectId,
        {...approval, status: 'revoked'});
      return value;
    },
    reserveOnce: (args) => state.store.reserveOnce(args),
  };
  const result = await reserveApprovedWebExecution({
    request: {projectId}, principal: {subject: ownerSubject}, store
  });
  assert.deepEqual(result, {ok:false,reason:'storage_inconsistent'});
  assert.equal(state.inserts,0);
  assert.equal(state.reservations.size,0);
});

test('same revision reapproval is idempotent, changed revision creates new key', async () => {
  const state = inMemoryD1();
  const first = await call(state);
  state.approvals.set(ownerSubject + ':' + projectId,
    {...approval, approvalId:'approval-2'});
  const same = await call(state);
  assert.equal(same.created, false);
  assert.equal(same.executionId, first.executionId);
  state.approvals.set(ownerSubject + ':' + projectId,
    {...approval, approvalId:'approval-3', currentRevision:2, approvedRevision:2,
      approvedSpecSha256:'b'.repeat(64)});
  const next = await call(state);
  assert.equal(next.created,true);
  assert.notEqual(next.executionId,first.executionId);
  assert.equal(state.inserts,2);
});

