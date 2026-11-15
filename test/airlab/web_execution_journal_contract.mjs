import test from 'node:test';
import assert from 'node:assert/strict';
import { createWebD1ExecutionJournal } from
  '../../scripts/web/d1_execution_journal_store.mjs';

const KEY = 'a'.repeat(64);
const ATTEMPT = '11111111-1111-4111-8111-111111111111';
const TOKEN = '22222222-2222-4222-8222-222222222222';
const WRONG = '33333333-3333-4333-8333-333333333333';
const ZIP_SHA = 'c'.repeat(64);

function setup() {
  const row = {
    status: 'reserved', journalVersion: 0, workerToken: null,
    artifactSha256: null, artifactSizeBytes: null, artifactStorageKey: null,
    attemptId: ATTEMPT, idempotencyKey: KEY,
  };
  let changes = 0;
  let shouldThrow = false;
  const events = [{ journalVersion: 0, toStatus: 'reserved' }];
  const receipts = [];
  const db = {
    prepare(sql) {
      if (shouldThrow) throw Error('secret internal storage error');
      return {
        bind(...args) {
          return {
            async run() {
              const [key, attempt, worker] = args;
              if (key !== KEY || attempt !== ATTEMPT) {
                return { success: true, meta: { changes: 0 } };
              }
              let changed = false;
              if (sql.includes("SET status = 'running'")) {
                if (row.status === 'reserved' && row.workerToken === null &&
                    worker === TOKEN) {
                  row.status = 'running'; row.workerToken = worker; changed = true;
                }
              } else if (sql.includes("SET status = 'completed'")) {
                if (row.status === 'running' && worker === row.workerToken &&
                    args[3] === ZIP_SHA && args[4] > 0) {
                  row.status = 'completed'; row.artifactSha256 = args[3];
                  row.artifactSizeBytes = args[4];
                  row.artifactStorageKey =
                    'web-artifacts/web-exec-1/' + args[3] + '.zip';
                  receipts.push({ executionId: 'web-exec-1',
                    artifactSha256: args[3], artifactSizeBytes: args[4] });
                  changed = true;
                }
              } else if (sql.includes("SET status = 'review_required'")) {
                if (row.status === 'running' && worker === row.workerToken) {
                  row.status = 'review_required'; changed = true;
                }
              } else if (sql.includes("SET status = 'failed'")) {
                if (sql.includes("'preflight'")) {
                  if (row.status === 'reserved') {
                    row.status = 'failed'; changed = true;
                  }
                } else if (worker === row.workerToken &&
                    ((row.status === 'running' &&
                      ['build', 'test', 'storage'].includes(args[3])) ||
                     (row.status === 'review_required' &&
                      args[3] === 'reconciliation'))) {
                  row.status = 'failed'; changed = true;
                }
              } else throw Error('Unexpected SQL mutation');
              if (changed) {
                changes++;
                row.journalVersion++;
                events.push({ journalVersion: row.journalVersion,
                  toStatus: row.status });
              }
              return { success: true, meta: { changes: Number(changed) } };
            },
            async first() {
              if (sql.includes('FROM web_execution_artifact_receipts')) {
                return receipts[0] || null;
              }
              throw Error('Unexpected read');
            },
            async all() {
              assert.match(sql, /web_execution_journal_events/);
              return { success: true, results: structuredClone(events) };
            },
          };
        },
      };
    },
  };
  const store = createWebD1ExecutionJournal(db);
  return { store, row, receipts, events, get changes() { return changes; },
    failDb() { shouldThrow = true; } };
}
const args = { key: KEY, attemptId: ATTEMPT, workerToken: TOKEN };
const artifact = { ...args, artifactSha256: ZIP_SHA, artifactSizeBytes: 1234,
  storageReadbackVerified: true, testsPassed: true };

test('25 concurrent worker claims result in one running attempt', async () => {
  const f = setup();
  const results = await Promise.all(Array.from({ length: 25 },
    () => f.store.claimReserved(args)));
  assert.equal(results.filter(x => x.ok).length, 1);
  assert.equal(f.changes, 1);
  assert.equal(f.row.status, 'running');
  assert.equal(f.row.journalVersion, 1);
  assert.equal(f.receipts.length, 0);
  assert.equal((await f.store.claimReserved(args)).reason,
    'stale_or_not_authorized');
});

test('completion requires trusted read-back and successful tests', async () => {
  const f = setup();
  await f.store.claimReserved(args);
  for (const value of [
    { ...artifact, storageReadbackVerified: false },
    { ...artifact, testsPassed: false },
    { ...artifact, artifactSha256: 'UPPERCASE' },
    { ...artifact, artifactSizeBytes: 0 },
    { ...artifact, artifactSizeBytes: 17 * 1024 * 1024 },
    { ...artifact, workerToken: WRONG },
  ]) {
    const response = await f.store.completeVerifiedArtifact(value);
    assert.equal(response.ok, false);
  }
  assert.equal(f.row.status, 'running');
  assert.equal(f.receipts.length, 0);
  assert.equal((await f.store.completeVerifiedArtifact(artifact)).ok, true);
  assert.equal(f.row.status, 'completed');
  assert.equal(f.receipts.length, 1);
  assert.equal((await f.store.completeVerifiedArtifact(artifact)).ok, false);
  assert.equal((await f.store.readImmutableReceipt(KEY)).value.artifactSha256,
    ZIP_SHA);
  const history = await f.store.readJournalEvents(KEY);
  assert.deepEqual(history.events.map(x => x.toStatus),
    ['reserved', 'running', 'completed']);
});

test('interrupted job requires operator reconciliation, never retry', async () => {
  const f = setup();
  await f.store.claimReserved(args);
  assert.equal((await f.store.flagInterruptedForReview(args)).ok, true);
  assert.equal(f.row.status, 'review_required');
  assert.equal((await f.store.claimReserved(args)).ok, false);
  assert.equal((await f.store.completeVerifiedArtifact(artifact)).ok, false);
  assert.equal((await f.store.failAttempt({
    ...args, failureKind: 'reconciliation',
  })).ok, true);
  assert.equal(f.row.status, 'failed');
  assert.equal(f.receipts.length, 0);
});

test('failed validation cannot create a completed artifact', async () => {
  const f = setup();
  await f.store.claimReserved(args);
  assert.equal((await f.store.failAttempt({
    ...args, failureKind: 'test',
  })).ok, true);
  assert.equal((await f.store.completeVerifiedArtifact(artifact)).ok, false);
  assert.equal(f.row.status, 'failed');
  assert.equal(f.receipts.length, 0);
});

test('missing D1, wrong attempt, malformed token and DB failures fail closed', async () => {
  assert.throws(() => createWebD1ExecutionJournal(null), /D1 binding required/);
  const f = setup();
  for (const bad of [
    { ...args, key: 'forged' },
    { ...args, attemptId: 'forged' },
    { ...args, workerToken: 'browser-provided' },
  ]) {
    assert.deepEqual(await f.store.claimReserved(bad),
      { ok: false, reason: 'invalid_request' });
  }
  assert.equal(f.changes, 0);
  assert.equal((await f.store.readJournalEvents('bad')).reason,
    'invalid_request');
  f.failDb();
  const r = await f.store.claimReserved(args);
  assert.deepEqual(r, { ok: false, reason: 'storage_unavailable' });
  assert.doesNotMatch(JSON.stringify(r), /secret|internal|SQL/);
});

test('preflight can fail without running side effects', async () => {
  const f = setup();
  assert.equal((await f.store.failPreflight({ key: KEY, attemptId: ATTEMPT })).ok, true);
  assert.equal(f.row.status, 'failed');
  assert.equal((await f.store.claimReserved(args)).ok, false);
  assert.equal(f.receipts.length, 0);
});
