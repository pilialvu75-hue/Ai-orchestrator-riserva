import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { onRequest as reserveExecution } from
  '../../functions/api/cantiere/executions/reserve.js';
import { onRequest as advanceExecution } from
  '../../functions/api/cantiere/executions/advance.js';
import { onRequest as readExecutionStatus } from
  '../../functions/api/cantiere/executions/status.js';
import { onRequest as downloadExecution } from
  '../../functions/api/cantiere/executions/download.js';
import { onRequest as stageCounter } from
  '../../functions/api/cantiere/proposals/counter.js';
import { onRequest as approveProposal } from
  '../../functions/api/cantiere/proposals/approve.js';
import { onRequest as generateApplication } from
  '../../functions/api/cantiere/proposals/generate.js';
import { onRequest as quotaApplication } from
  '../../functions/api/cantiere/proposals/quota.js';
import { onRequest as reuseApplication } from
  '../../functions/api/cantiere/proposals/reuse.js';
import { onRequestBroker as ordinaryInference } from '../../functions/api/cantiere/inference.js';
import { createWebBuilderInference, listWebBuilderLargeModels } from
  '../../functions/api/cantiere/inference.js';
import { generateWebApplication } from '../../scripts/web/generate_web_application.mjs';
import { onRequest as cloudCapabilities } from '../../functions/api/cantiere/capabilities.js';
import { createAuthenticatedWebProjectOperation } from
  '../../scripts/web/authenticated_web_project_operation.mjs';
import { existingWebOwnerSubject } from '../../scripts/web/web_owner_role.mjs';
import { runWebCounterAttempt } from '../../scripts/web/run_web_counter_attempt.mjs';
import { buildAndTestCounter } from '../../scripts/web/build_verified_counter_zip.mjs';
import { sealCounterRunnerZip } from '../../scripts/web/counter_runner_envelope.mjs';
import {
  dispatchReservedWebCounter, readWebCounterDispatch,
} from '../../scripts/web/d1_web_counter_dispatch.mjs';
import {
  createD1WebCounterArtifactStore, MAX_COUNTER_D1_ZIP_BYTES,
} from '../../scripts/web/d1_web_counter_artifact_store.mjs';

const issuer = 'https://aivexus-test.cloudflareaccess.com';
const audience = 'test-web-access-application';
const origin = 'https://aivexus.pages.dev';
const now = 1794660000;
const subject = 'access-subject-a';
const projectId = 'web-counter';
const digest = 'a'.repeat(64);

async function signer() {
  const keys = await crypto.subtle.generateKey({
    name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256',
  }, true, ['sign', 'verify']);
  const pub = await crypto.subtle.exportKey('jwk', keys.publicKey);
  const jwk = { ...pub, kid: 'test-web-key', alg: 'RS256', use: 'sig' };
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  async function sign(payload = {}) {
    const head = encode({ alg: 'RS256', typ: 'JWT', kid: 'test-web-key' });
    const body = encode({
      iss: issuer, aud: [audience], sub: subject, iat: now - 100,
      nbf: now - 100, exp: now + 600, ...payload,
    });
    const signed = head + '.' + body;
    const signature = await crypto.subtle.sign({
      name: 'RSASSA-PKCS1-v1_5',
    }, keys.privateKey, new TextEncoder().encode(signed));
    return signed + '.' + Buffer.from(signature).toString('base64url');
  }
  return { jwk, sign };
}

function d1Fixture() {
  const approval = {
    product: 'aivexus-web', ownerSubject: subject, projectId,
    status: 'proposal_ready', currentRevision: 1,
    proposalSpecSha256: digest, approvedRevision: null,
    approvedSpecSha256: null, approvalId: null,
  };
  const reservations = new Map();
  const audit = [];
  let prepareCount = 0;
  let changedCount = 0;
  let shouldFail = false;
  const db = {
    prepare(sql) {
      prepareCount++;
      if (shouldFail) throw new Error('PRIVATE DB SQL and service token');
      return {
        bind(...args) {
          return {
            async first() {
              if (sql.includes('FROM web_project_approvals') &&
                  !sql.includes('INSERT')) {
                const [owner, project] = args;
                return approval.ownerSubject === owner &&
                  approval.projectId === project ? { ...approval } : null;
              }
              if (sql.includes('FROM web_execution_reservations')) {
                if (sql.includes('LIMIT 1')) {
                  const [owner, project] = args;
                  return [...reservations.values()]
                    .filter(row => row.ownerSubject === owner && row.projectId === project)
                    .sort((a, b) => b.revision - a.revision)[0] ?? null;
                }
                return reservations.get(args[0]) || null;
              }
              throw new Error('Unexpected SELECT');
            },
            async run() {
              let changes = 0;
              if (sql.includes("SET status = 'approved'")) {
                const [owner, id, rev, hash, approvalId] = args;
                if (approval.ownerSubject === owner && approval.projectId === id &&
                    approval.currentRevision === rev &&
                    approval.proposalSpecSha256 === hash &&
                    approval.status === 'proposal_ready' &&
                    approval.approvedRevision === null &&
                    approval.approvalId === null) {
                  approval.status = 'approved';
                  approval.approvedRevision = rev;
                  approval.approvedSpecSha256 = approval.proposalSpecSha256;
                  approval.approvalId = approvalId;
                  audit.push('approved'); changes = 1;
                }
              } else if (sql.includes("SET status = 'revoked'")) {
                const [owner, id, rev, approvalId] = args;
                if (approval.ownerSubject === owner && approval.projectId === id &&
                    approval.currentRevision === rev &&
                    approval.approvalId === approvalId &&
                    approval.status === 'approved') {
                  approval.status = 'revoked';
                  approval.approvedRevision = null;
                  approval.approvedSpecSha256 = null;
                  approval.approvalId = null;
                  audit.push('revoked'); changes = 1;
                }
              } else if (sql.includes('INSERT OR IGNORE INTO web_execution_reservations')) {
                const [key, owner, id, rev, spec, executionId, attemptId,
                  createdAt, approvalId] = args;
                if (!reservations.has(key) &&
                    approval.ownerSubject === owner &&
                    approval.projectId === id &&
                    approval.currentRevision === rev &&
                    approval.approvedRevision === rev &&
                    approval.approvedSpecSha256 === spec &&
                    approval.status === 'approved' &&
                    approval.approvalId === approvalId) {
                  reservations.set(key, {
                    idempotencyKey: key, ownerSubject: owner, projectId: id,
                    revision: rev, approvedSpecSha256: spec, approvalId,
                    executionId, attemptId, status: 'reserved',
                    artifactSha256: null, createdAt,
                  });
                  changes = 1;
                }
              } else {
                throw new Error('Unexpected UPDATE or INSERT');
              }
              changedCount += changes;
              return { success: true, meta: { changes } };
            },
          };
        },
      };
    },
  };
  return {
    db, approval, audit, reservations,
    get prepares() { return prepareCount; },
    get changes() { return changedCount; },
    failDb() { shouldFail = true; },
  };
}

function webRequest(token, payload, {
  requestOrigin = origin, method = 'POST',
  type = 'application/json', site = 'same-origin',
  path = '/api/cantiere/private/project-operation',
} = {}) {
  const headers = new Headers();
  if (token !== null) headers.set('Cf-Access-Jwt-Assertion', token);
  if (requestOrigin !== null) headers.set('Origin', requestOrigin);
  if (type !== null) headers.set('Content-Type', type);
  if (site !== null) headers.set('Sec-Fetch-Site', site);
  return new Request(origin + path, {
    method, headers,
    ...(method !== 'GET' ? { body: typeof payload === 'string'
      ? payload : JSON.stringify(payload) } : {}),
  });
}
function setup(f, signing, operation = 'approve', opts = {}) {
  let fetches = 0;
  const handler = createAuthenticatedWebProjectOperation({
    operation, expectedOrigin: origin, accessIssuer: issuer,
    accessAudience: audience, db: f.db, nowSeconds: () => now,
    fetchImpl: async (url, init) => {
      fetches++;
      assert.equal(url, issuer + '/cdn-cgi/access/certs');
      assert.equal(init.redirect, 'manual');
      return new Response(JSON.stringify({ keys: [signing.jwk] }), {
        headers: { 'Content-Type': 'application/json' },
      });
    },
    ...opts,
  });
  return { handler, get fetches() { return fetches; } };
}
async function body(response) {
  const value = await response.json();
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('access-control-allow-origin'), null);
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  return value;
}

test('authenticated approval writes only the stored proposal digest and then rejects replay', async () => {
  const signing = await signer();
  const f = d1Fixture();
  const gate = setup(f, signing);
  const token = await signing.sign();
  const payload = { projectId, expectedRevision: 1, expectedSpecSha256: digest };
  const response = await gate.handler(webRequest(token, payload));
  assert.equal(response.status, 200);
  const data = await body(response);
  assert.equal(data.ok, true);
  assert.equal(data.approvedRevision, 1);
  assert.equal(f.approval.approvedSpecSha256, digest);
  assert.equal(f.audit.length, 1);
  assert.doesNotMatch(JSON.stringify(data), /access-subject|private|token|digest/);
  const replay = await gate.handler(webRequest(token, payload));
  assert.equal(replay.status, 409);
  assert.deepEqual(await body(replay), {
    version: 1, ok: false, error: 'approval_not_ready',
  });
  assert.equal(f.audit.length, 1);
  assert.equal(gate.fetches, 1);
});

test('no assertion, forged cookie, wrong issuer or audience never reaches D1', async () => {
  const signing = await signer();
  const f = d1Fixture();
  const gate = setup(f, signing);
  const payload = { projectId, expectedRevision: 1, expectedSpecSha256: digest };
  const missing = webRequest(null, payload);
  missing.headers.set('Cookie', 'CF_Authorization=forged');
  missing.headers.set('X-Principal', subject);
  assert.equal((await gate.handler(missing)).status, 401);
  assert.equal(gate.fetches, 0);
  for (const claims of [
    { iss: 'https://evil.cloudflareaccess.com' },
    { aud: ['another-cloudflare-app'] },
    { exp: now - 1 },
    { sub: '' },
  ]) {
    const r = await gate.handler(webRequest(await signing.sign(claims), payload));
    assert.equal(r.status, 401);
    assert.deepEqual(await body(r), { version: 1, ok: false, error: 'access_denied' });
  }
  assert.equal(f.prepares, 0);
});

test('wrong origin, missing origin, cross-site, GET and invalid server origin fail before identity or D1', async () => {
  const signing = await signer();
  const f = d1Fixture();
  const gate = setup(f, signing);
  const token = await signing.sign();
  const payload = { projectId, expectedRevision: 1, expectedSpecSha256: digest };
  for (const opt of [
    { requestOrigin: 'https://evil.example' },
    { requestOrigin: null },
    { site: 'cross-site' },
  ]) {
    assert.equal((await gate.handler(webRequest(token, payload, opt))).status, 403);
  }
  assert.equal((await gate.handler(webRequest(token, null, { method: 'GET' }))).status, 405);
  const invalid = setup(f, signing, 'approve', { expectedOrigin: 'https://evil.example/foo' });
  assert.equal((await invalid.handler(webRequest(token, payload))).status, 503);
  assert.equal(f.prepares, 0);
  assert.equal(gate.fetches, 0);
});

test('wrong content type, malformed JSON, oversized body and forged fields never mutate D1', async () => {
  const signing = await signer();
  const f = d1Fixture();
  const gate = setup(f, signing);
  const token = await signing.sign();
  const payload = { projectId, expectedRevision: 1, expectedSpecSha256: digest };
  const requests = [
    [webRequest(token, payload, { type: 'text/plain' }), 415],
    [webRequest(token, '{invalid'), 400],
    [webRequest(token, { ...payload, extra: 'x'.repeat(6000) }), 413],
    [webRequest(token, { ...payload, approved: true }), 400],
    [webRequest(token, { ...payload, ownerSubject: subject }), 400],
    [webRequest(token, { ...payload, verifiedBy: 'cloudflare-access-jwt' }), 400],
  ];
  for (const [req, status] of requests) {
    assert.equal((await gate.handler(req)).status, status);
  }
  assert.equal(f.changes, 0);
  assert.equal(f.audit.length, 0);
});

test('approved revision can be reserved once; repeat is idempotent, revocation blocks new reservations', async () => {
  const signing = await signer();
  const f = d1Fixture();
  const token = await signing.sign();
  const approve = setup(f, signing, 'approve');
  const reserve = setup(f, signing, 'reserve');
  const revoke = setup(f, signing, 'revoke');
  const firstApproval = await body(await approve.handler(webRequest(token, {
    projectId, expectedRevision: 1, expectedSpecSha256: digest,
  })));
  assert.equal(firstApproval.ok, true);
  const reservationPayload = { projectId };
  const responses = await Promise.all(Array.from({ length: 25 }, () =>
    reserve.handler(webRequest(token, reservationPayload))));
  const records = await Promise.all(responses.map(body));
  assert.equal(records.filter(x => x.created).length, 1);
  assert.equal(f.reservations.size, 1);
  assert.equal(new Set(records.map(x => x.executionId)).size, 1);
  assert.equal(new Set(records.map(x => x.attemptId)).size, 1);
  assert.equal(records[0].status, 'reserved');
  assert.equal(records[0].artifactSha256, undefined);

  const revoked = await revoke.handler(webRequest(token, {
    projectId, expectedRevision: 1, approvalId: firstApproval.approvalId,
  }));
  assert.equal(revoked.status, 200);
  assert.equal((await body(revoked)).status, 'revoked');
  assert.equal(f.audit.join(','), 'approved,revoked');
  const after = await reserve.handler(webRequest(token, reservationPayload));
  assert.equal(after.status, 409);
  assert.equal(f.reservations.size, 1);
});

test('browser cannot choose server operation or reserve with spoofed approval', async () => {
  const signing = await signer();
  const f = d1Fixture();
  const token = await signing.sign();
  const reserve = setup(f, signing, 'reserve');
  assert.equal((await reserve.handler(webRequest(token, {
    projectId, approved: true, operation: 'approve', principal: subject,
  }))).status, 400);
  assert.equal((await reserve.handler(webRequest(token, { projectId }))).status, 409);
  assert.equal(f.reservations.size, 0);
  const invalid = setup(f, signing, 'build-and-deploy');
  assert.equal((await invalid.handler(webRequest(token, { projectId }))).status, 503);
});

test('Pages routes reserve once and recover status for the verified owner', async t => {
  const signing = await signer();
  const f = d1Fixture();
  const issuedAt = Math.floor(Date.now() / 1000) - 10;
  const claims = { iat: issuedAt, nbf: issuedAt, exp: issuedAt + 300 };
  const token = await signing.sign(claims);
  const otherToken = await signing.sign({ ...claims, sub: 'access-subject-b' });
  const env = {
    AIVEXUS_WEB_ORIGIN: origin,
    AIVEXUS_WEB_ACCESS_ISSUER: issuer,
    AIVEXUS_WEB_ACCESS_AUDIENCE: audience,
    AIVEXUS_WEB_D1: f.db,
  };
  t.mock.method(globalThis, 'fetch', async url => {
    assert.equal(url, issuer + '/cdn-cgi/access/certs');
    return Response.json({ keys: [signing.jwk] });
  });
  const send = (assertion, options, bindings = env) => reserveExecution({
    request: webRequest(assertion, { projectId }, {
      path: '/api/cantiere/executions/reserve', ...options,
    }),
    env: bindings,
  });

  assert.equal((await send(null)).status, 401);
  assert.equal((await send(token, { requestOrigin: null })).status, 403);
  assert.equal((await send(token, {}, {})).status, 503);
  assert.equal((await send(token, {}, { ...env, AIVEXUS_WEB_ACCESS_AUDIENCE: '' })).status, 503);
  assert.equal(f.prepares, 0);
  assert.equal((await send(token)).status, 409);

  const approve = setup(f, signing, 'approve');
  const approval = await approve.handler(webRequest(await signing.sign(), {
    projectId, expectedRevision: 1, expectedSpecSha256: digest,
  }));
  assert.equal(approval.status, 200);
  assert.equal((await send(otherToken)).status, 409);
  assert.equal(f.reservations.size, 0);

  const first = await body(await send(token));
  const replay = await body(await send(token));
  assert.equal(first.status, 'reserved');
  assert.equal(first.created, true);
  assert.equal(replay.created, false);
  assert.equal(replay.executionId, first.executionId);
  assert.equal(replay.attemptId, first.attemptId);
  assert.equal(f.reservations.size, 1);

  const status = (assertion, query = '?projectId=' + projectId, options = {}) =>
    readExecutionStatus({
      request: webRequest(assertion, null, {
        path: '/api/cantiere/executions/status' + query,
        requestOrigin: null, method: 'GET', ...options,
      }),
      env,
    });
  const prepared = f.prepares;
  const changes = f.changes;
  assert.equal((await status(null)).status, 401);
  assert.equal((await status(token, undefined, { site: 'cross-site' })).status, 403);
  assert.equal((await status(token, '?projectId=x&projectId=y')).status, 400);
  assert.equal(f.prepares, prepared);
  assert.deepEqual(await body(await status(otherToken)), {
    version: 1, ok: false, error: 'execution_not_found',
  });
  assert.deepEqual(await body(await status(token)), {
    version: 1, ok: true, revision: 1, status: 'reserved',
    executionId: first.executionId, attemptId: first.attemptId,
  });
  assert.equal(f.changes, changes);
});

function sqliteD1(t, migrations) {
  const sqlite = new DatabaseSync(':memory:');
  t.after(() => sqlite.close());
  for (const name of migrations) {
    sqlite.exec(readFileSync(new URL('../../scripts/web/sql/' + name, import.meta.url), 'utf8'));
  }
  const db = {
    prepare(sql) {
      const statement = sqlite.prepare(sql);
      return {
        bind(...args) {
          const params = Object.fromEntries(args.map((value, index) => [
            '?' + (index + 1), value instanceof ArrayBuffer ? new Uint8Array(value) : value,
          ]));
          return {
            first: async column => {
              const row = statement.get(params);
              return (column ? row?.[column] : row) ?? null;
            },
            run: async () => {
              const totalChanges = sqlite.prepare('SELECT total_changes() AS count');
              const before = totalChanges.get().count;
              statement.run(params);
              return { success: true, meta: { changes: totalChanges.get().count - before } };
            },
          };
        },
      };
    },
  };
  return { db, sqlite };
}

test('Pages stages and approves a counter, then serves only its verified ZIP to its owner', async t => {
  const { db, sqlite } = sqliteD1(t, [
    '001_web_approval_reservation.sql',
    '002_web_proposal_approval_audit.sql',
    '003_web_execution_journal.sql',
    '004_web_counter_artifacts.sql',
    '005_web_counter_dispatch.sql',
  ]);
  const signing = await signer();
  const issuedAt = Math.floor(Date.now() / 1000) - 10;
  const claims = { iat: issuedAt, nbf: issuedAt, exp: issuedAt + 300 };
  const token = await signing.sign(claims);
  const otherToken = await signing.sign({ ...claims, sub: 'access-subject-b' });
  let zip;
  let stored;
  let objectReads = 0;
  let objectWrites = 0;
  let sha256;
  const bucket = {
    async put(key, bytes, options) {
      assert.match(key, new RegExp('^web-artifacts/web-exec-[0-9a-f]{32}/' + sha256 + '\\.zip$'));
      assert.equal(options.onlyIf.get('If-None-Match'), '*');
      objectWrites++;
      if (stored) return null;
      stored = Buffer.from(bytes);
      return { size: stored.length };
    },
    async get() {
      objectReads++;
      return stored ? {
        size: stored.length,
        arrayBuffer: async () => Uint8Array.from(stored).buffer,
      } : null;
    },
  };
  const env = {
    AIVEXUS_WEB_ORIGIN: origin,
    AIVEXUS_WEB_ACCESS_ISSUER: issuer,
    AIVEXUS_WEB_ACCESS_AUDIENCE: audience,
    AIVEXUS_WEB_D1: db,
    AIVEXUS_WEB_ARTIFACTS: bucket,
  };
  let githubFixture;
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    if (url === issuer + '/cdn-cgi/access/certs') return Response.json({ keys: [signing.jwk] });
    assert.ok(githubFixture, 'Unexpected external request');
    return githubFixture(url, options);
  });
  const send = (route, path, assertion, payload) =>
    route({ request: webRequest(assertion, payload, { path }), env });
  const stage = (assertion, payload) =>
    send(stageCounter, '/api/cantiere/proposals/counter', assertion, payload);
  const approve = (assertion, payload) =>
    send(approveProposal, '/api/cantiere/proposals/approve', assertion, payload);
  const reserve = assertion =>
    send(reserveExecution, '/api/cantiere/executions/reserve', assertion, { projectId });

  assert.equal((await stage(null, { projectId })).status, 401);
  assert.equal((await stage(token, { projectId, approved: true })).status, 400);
  const staged = await Promise.all(Array.from({ length: 8 }, () => stage(token, { projectId })));
  assert.ok(staged.every(response => response.status === 200));
  const proposal = await body(staged[0]);
  assert.equal(proposal.revision, 1);
  assert.equal(proposal.status, 'proposal_ready');
  assert.equal(proposal.specSha256, '7d0da7c7ea33af0fa75196e6d627d6a2c600c04bc09923ff86e648689bc827af');
  assert.equal(sqlite.prepare('SELECT COUNT(*) AS count FROM web_project_approvals').get().count, 1);
  assert.equal((await reserve(token)).status, 409);

  const approval = { projectId, expectedRevision: 1, expectedSpecSha256: proposal.specSha256 };
  assert.equal((await approve(otherToken, approval)).status, 409);
  assert.equal((await approve(token, { ...approval, expectedSpecSha256: digest })).status, 409);
  assert.equal((await approve(token, approval)).status, 200);
  assert.equal((await body(await stage(token, { projectId }))).status, 'approved');
  const reserved = await body(await reserve(token));
  assert.equal(reserved.status, 'reserved');
  assert.equal((await body(await reserve(token))).executionId, reserved.executionId);
  assert.equal(sqlite.prepare('SELECT COUNT(*) AS count FROM web_approval_audit').get().count, 1);
  assert.equal(sqlite.prepare('SELECT COUNT(*) AS count FROM web_execution_journal_events').get().count, 1);

  const download = assertion => downloadExecution({
    request: webRequest(assertion, null, {
      method: 'GET', requestOrigin: null,
      path: '/api/cantiere/executions/download?executionId=' + reserved.executionId,
    }),
    env,
  });
  assert.equal((await download(null)).status, 401);
  assert.equal((await download(token)).status, 404);
  assert.equal(objectReads, 0);

  const key = sqlite.prepare('SELECT idempotency_key AS key FROM web_execution_reservations').get().key;
  let builds = 0;
  const attempt = {
    db, bucket, key, attemptId: reserved.attemptId,
    buildAndTestCounter: async () => {
      builds++;
      zip = await buildAndTestCounter();
      sha256 = createHash('sha256').update(zip).digest('hex');
      return zip;
    },
  };
  const attempts = await Promise.all(Array.from({ length: 8 }, () => runWebCounterAttempt(attempt)));
  assert.equal(attempts.filter(result => result.ok).length, 1);
  assert.equal(builds, 1);
  assert.ok(zip.length > 0);
  assert.equal(objectWrites, 1);
  assert.equal(objectReads, 1);
  assert.equal((await download(otherToken)).status, 404);
  assert.equal(objectReads, 1);
  const response = await download(token);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'application/zip');
  assert.match(response.headers.get('content-disposition'), /^attachment;/);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), zip);
  stored = Buffer.alloc(zip.length);
  assert.deepEqual(await body(await download(token)), {
    version: 1, ok: false, error: 'artifact_unavailable',
  });

  const secondProjectId = 'second-counter';
  assert.equal((await stage(token, { projectId: secondProjectId })).status, 200);
  assert.equal((await approve(token, { ...approval, projectId: secondProjectId })).status, 200);
  const second = await body(await send(
    reserveExecution, '/api/cantiere/executions/reserve', token, { projectId: secondProjectId },
  ));
  const secondKey = sqlite.prepare(
    'SELECT idempotency_key AS key FROM web_execution_reservations WHERE execution_id = ?',
  ).get(second.executionId).key;
  let ambiguousPosts = 0;
  const ambiguous = {
    db, ownerSubject: subject, executionId: second.executionId,
    expectedHeadSha: '1'.repeat(40), publicKeySpki: 'YWJj',
    github: { async dispatch() { ambiguousPosts++; throw new Error('Connection lost'); } },
  };
  assert.deepEqual(await dispatchReservedWebCounter(ambiguous), { state: 'review_required' });
  assert.deepEqual(await dispatchReservedWebCounter(ambiguous), { state: 'review_required' });
  assert.equal(ambiguousPosts, 1);
  const collision = {
    ...attempt, key: secondKey, attemptId: second.attemptId,
    buildAndTestCounter: async () => zip,
    bucket: { put: async () => null, get: async () => assert.fail('Unexpected object read') },
  };
  assert.deepEqual(await runWebCounterAttempt(collision), { ok: false, reason: 'review_required' });
  assert.equal((await runWebCounterAttempt(collision)).ok, false);
  assert.equal(sqlite.prepare(
    'SELECT status FROM web_execution_reservations WHERE execution_id = ?',
  ).get(second.executionId).status, 'review_required');
  assert.equal(sqlite.prepare('SELECT COUNT(*) AS count FROM web_execution_artifact_receipts').get().count, 1);

  const d1ProjectId = 'counter-d1-storage';
  assert.equal((await stage(token, { projectId: d1ProjectId })).status, 200);
  assert.equal((await approve(token, { ...approval, projectId: d1ProjectId })).status, 200);
  const d1Execution = await body(await send(
    reserveExecution, '/api/cantiere/executions/reserve', token, { projectId: d1ProjectId },
  ));
  const d1Key = sqlite.prepare(
    'SELECT idempotency_key AS key FROM web_execution_reservations WHERE execution_id = ?',
  ).get(d1Execution.executionId).key;
  let dispatches = 0;
  const dispatch = {
    ...ambiguous, executionId: d1Execution.executionId,
    github: { async dispatch() { dispatches++; return 1234; } },
  };
  assert.deepEqual(await dispatchReservedWebCounter({ ...dispatch, ownerSubject: 'other' }),
    { state: 'not_found' });
  await Promise.all(Array.from({ length: 8 }, () => dispatchReservedWebCounter(dispatch)));
  assert.equal(dispatches, 1);
  const submitted = await readWebCounterDispatch(dispatch);
  assert.equal(submitted.runId, 1234);
  assert.equal(submitted.executionKey, d1Key);
  assert.equal(submitted.headSha, dispatch.expectedHeadSha);
  assert.deepEqual(await dispatchReservedWebCounter(dispatch), { state: 'submitted' });
  const { publicKey, privateKey } = await crypto.subtle.generateKey({
    name: 'RSA-OAEP', modulusLength: 2048, hash: 'SHA-256',
    publicExponent: new Uint8Array([1, 0, 1]),
  }, true, ['encrypt', 'decrypt']);
  const envelope = await sealCounterRunnerZip({ publicKey, ticket: submitted.ticket, zip });
  const archive = execFileSync(process.env.AIVEXUS_COUNTER_PYTHON || 'python3', ['-c', [
    'import io, sys, zipfile',
    'out = io.BytesIO()',
    "with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_STORED) as z:",
    "    z.writestr('counter.aivexus', sys.stdin.buffer.read())",
    'sys.stdout.buffer.write(out.getvalue())',
  ].join('\n')], { input: envelope });
  const repo = { id: 1235011890 };
  const api = 'https://api.github.com/repos/pilialvu75-hue/Ai-orchestrator-riserva/actions';
  const storageUrl = 'https://counter-fixture.blob.core.windows.net/opaque';
  let remoteState = 'pending';
  let archiveReads = 0;
  githubFixture = (url, options) => {
    if (url === api + '/runs/1234') return Response.json({
      id: 1234, event: 'workflow_dispatch', run_attempt: 1, repository: repo,
      head_repository: repo, head_branch: 'main', head_sha: dispatch.expectedHeadSha,
      path: '.github/workflows/web-counter-runner.yml',
      status: remoteState === 'ready' ? 'completed' : 'in_progress', conclusion: 'success',
    });
    if (url === api + '/runs/1234/artifacts?per_page=2') return Response.json({
      total_count: 1,
      artifacts: [{
        id: 4321, name: 'aivexus-counter-envelope', expired: false,
        size_in_bytes: archive.length, digest: 'sha256:' + createHash('sha256').update(archive).digest('hex'),
        workflow_run: { id: 1234, repository_id: repo.id, head_repository_id: repo.id,
          head_branch: 'main', head_sha: dispatch.expectedHeadSha },
      }],
    });
    if (url === api + '/artifacts/4321/zip') {
      return new Response(null, { status: 302, headers: { location: storageUrl } });
    }
    assert.equal(url, storageUrl);
    assert.equal(options.headers, undefined);
    archiveReads++;
    return new Response(archive);
  };
  const runnerEnv = {
    ...env, AIVEXUS_WEB_ARTIFACTS: undefined,
    AIVEXUS_COUNTER_GITHUB_HEAD_SHA: dispatch.expectedHeadSha,
    AIVEXUS_COUNTER_GITHUB_TOKEN: 'local-fixture',
    AIVEXUS_COUNTER_PUBLIC_KEY: Buffer.from(await crypto.subtle.exportKey('spki', publicKey)).toString('base64'),
    AIVEXUS_COUNTER_PRIVATE_KEY: Buffer.from(await crypto.subtle.exportKey('pkcs8', privateKey)).toString('base64'),
  };
  const advance = assertion => advanceExecution({
    request: webRequest(assertion, { executionId: d1Execution.executionId }, {
      path: '/api/cantiere/executions/advance',
    }),
    env: runnerEnv,
  });
  assert.equal((await advance(otherToken)).status, 404);
  assert.equal((await body(await advance(token))).status, 'submitted');
  assert.equal(archiveReads, 0);
  const recovered = await readExecutionStatus({
    request: webRequest(token, null, {
      method: 'GET', requestOrigin: null,
      path: '/api/cantiere/executions/status?projectId=' + d1ProjectId,
    }),
    env,
  });
  assert.equal((await body(recovered)).status, 'submitted');
  remoteState = 'ready';
  assert.deepEqual(await body(await advance(token)),
    { version: 1, ok: true, executionId: d1Execution.executionId, status: 'completed' });
  assert.equal((await body(await advance(token))).status, 'completed');
  assert.equal(archiveReads, 1);

  const d1Store = createD1WebCounterArtifactStore(db);
  const d1StorageKey = `web-artifacts/${d1Execution.executionId}/${sha256}.zip`;
  assert.equal(await d1Store.put(d1StorageKey, Buffer.alloc(zip.length)), null);
  await assert.rejects(() => d1Store.put(d1StorageKey, new Uint8Array(MAX_COUNTER_D1_ZIP_BYTES + 1)),
    RangeError);
  const downloadFromD1 = assertion => downloadExecution({
    request: webRequest(assertion, null, {
      method: 'GET', requestOrigin: null,
      path: '/api/cantiere/executions/download?executionId=' + d1Execution.executionId,
    }),
    env: { ...env, AIVEXUS_WEB_ARTIFACTS: undefined },
  });
  assert.equal((await downloadFromD1(otherToken)).status, 404);
  const d1Response = await downloadFromD1(token);
  assert.equal(d1Response.status, 200);
  assert.deepEqual(Buffer.from(await d1Response.arrayBuffer()), zip);
  assert.equal(sqlite.prepare('SELECT COUNT(*) AS count FROM web_counter_artifacts').get().count, 1);
});

test('Pages generates and persists sources through the dedicated free route', async t => {
  const { db, sqlite } = sqliteD1(t, ['006_web_app_generations.sql']);
  const signing = await signer();
  const iat = Math.floor(Date.now() / 1000) - 10;
  const token = await signing.sign({ iat, nbf: iat, exp: iat + 300 });
  const otherToken = await signing.sign({ iat, nbf: iat, exp: iat + 300, sub: 'other-owner' });
  const model = '@cf/google/gemma-4-26b-a4b-it';
  const env = {
    AIVEXUS_WEB_ORIGIN: origin,
    AIVEXUS_WEB_ACCESS_ISSUER: issuer,
    AIVEXUS_WEB_ACCESS_AUDIENCE: audience,
    AIVEXUS_WEB_D1: db,
    AIVEXUS_WEB_BUILDER_FREE_ENABLED: 'true',
  };
  const path = '/api/cantiere/proposals/generate';
  const submit = (assertion, payload, bindings = env, requestOrigin = origin) => generateApplication({
    request: webRequest(assertion, payload, { path, requestOrigin }), env: bindings,
  });
  const status = (assertion, query) => generateApplication({
    request: webRequest(assertion, undefined, { method: 'GET', path: `${path}?${query}`, requestOrigin: null }),
    env,
  });
  const first = { generationId: crypto.randomUUID(), prompt: 'Un timer per infusi con pausa.' };
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  const prompts = [];
  let release;
  const wait = new Promise(resolve => { release = resolve; });
  const cases = new Map([
    [first.prompt, { title: 'Timer per infusi', file: 'timer.mjs' }],
    ['Una scheda per annotare libri.', { title: 'Libri', file: 'notes.css' }],
    ['Una tabella per calcolare medie.', { title: 'Medie', file: 'averages.js' }],
  ]);
  let started;
  const reachedProvider = new Promise(resolve => { started = resolve; });
  globalThis.fetch = async url => {
    assert.equal(String(url), `${issuer}/cdn-cgi/access/certs`);
    return Response.json({ keys: [signing.jwk] });
  };
  env.AIVEXUS_WEB_BUILDER_AI = { async run(selectedModel, request) {
    assert.equal(selectedModel, model);
    assert.equal(request.max_tokens, 4096);
    assert.equal(request.store, false);
    const prompt = request.messages.at(-1).content;
    prompts.push(prompt);
    if (prompt === first.prompt) {
      started();
      await wait;
    }
    if (prompt === 'Provider non disponibile') throw new Error('Simulated quota error');
    const fixture = cases.get(prompt);
    return {
      model,
      choices: [{ finish_reason: 'stop', message: { content: JSON.stringify({
        title: fixture?.title ?? 'Fixture non valida', requirements: [prompt],
        files: [
          { path: 'index.html', content: `<h1>${fixture?.title ?? 'Test'}</h1>` },
          { path: fixture?.file ?? '../index.html', content: 'source fixture' },
        ],
      }) } }], usage: { completion_tokens: 100 },
    };
  } };

  assert.equal((await submit(null, first)).status, 401);
  assert.equal((await submit(token, first, env, 'https://different.invalid')).status, 403);
  assert.equal((await submit(token, first, { ...env, AIVEXUS_WEB_BUILDER_FREE_ENABLED: 'false' })).status, 503);
  assert.equal((await submit(token, first, {
    ...env, AIVEXUS_WEB_BUILDER_AI: undefined,
  })).status, 503);
  const capabilityResponse = await cloudCapabilities({ request: new Request(origin), env });
  assert.deepEqual((await capabilityResponse.json()).capabilities, []);
  const normalResponse = await ordinaryInference({
    request: webRequest(token, { version: 1, capability: 'coding', messages: [{ role: 'user', content: first.prompt }] }),
    env,
  });
  assert.equal(normalResponse.status, 503);
  assert.deepEqual(prompts, []);

  const pending = submit(token, first);
  try {
    await Promise.race([
      reachedProvider,
      pending.then(response => assert.fail(`Provider did not receive request (HTTP ${response.status})`)),
    ]);
    const replay = await Promise.all(Array.from({ length: 4 }, () => submit(token, first)));
    for (const response of replay) assert.equal((await response.json()).status, 'generating');
    assert.equal((await (await status(token, `generationId=${first.generationId}`)).json()).status, 'generating');
  } finally {
    release();
  }
  const result = await (await pending).json();
  assert.equal(result.status, 'generated');
  assert.equal(result.provenance.reportedModel, model);
  assert.deepEqual(result.paths, ['index.html', 'timer.mjs']);
  assert.deepEqual(await (await submit(token, first)).json(), result);
  assert.deepEqual(await (await status(token, `generationId=${first.generationId}`)).json(), result);
  assert.equal((await status(otherToken, `generationId=${first.generationId}`)).status, 404);
  assert.equal((await status(token, `generationId=${first.generationId}&prompt=unexpected`)).status, 400);
  assert.equal((await status(null, `generationId=${first.generationId}`)).status, 401);
  assert.equal((await submit(token, { ...first, prompt: 'Un altro prompt' })).status, 409);
  assert.equal((await submit(otherToken, first, { ...env, AIVEXUS_WEB_BUILDER_FREE_ENABLED: 'false' })).status, 503);
  assert.deepEqual(prompts, [first.prompt]);

  const hashes = new Set([result.sourceSha256]);
  for (const prompt of [...cases.keys()].slice(1)) {
    const next = await (await submit(token, { generationId: crypto.randomUUID(), prompt })).json();
    assert.equal(next.status, 'generated');
    assert.ok(next.paths.includes(cases.get(prompt).file));
    hashes.add(next.sourceSha256);
  }
  assert.equal(hashes.size, 3);
  assert.deepEqual(prompts, [...cases.keys()]);
  const saved = sqlite.prepare('SELECT result_json FROM web_app_generations WHERE generation_id = ?').get(first.generationId);
  const stored = JSON.parse(saved.result_json);
  assert.match(stored.source.files[0].content, /Timer per infusi/);
  assert.equal(createHash('sha256').update(JSON.stringify(stored.source)).digest('hex'), result.sourceSha256);

  for (const prompt of ['Percorso non valido', 'Provider non disponibile']) {
    const bad = { generationId: crypto.randomUUID(), prompt };
    assert.equal((await (await submit(token, bad)).json()).status, 'failed');
    assert.equal((await (await submit(token, bad)).json()).status, 'failed');
    assert.equal(prompts.filter(value => value === prompt).length, 1);
  }
  // Four additional recorded reservations bring the owner to nine attempts.
  // These rows do not trigger inference in this test fixture.
  const quotaSeed = sqlite.prepare("INSERT INTO web_app_generations (owner_subject, generation_id, prompt_sha256, status) VALUES (?, ?, ?, 'failed')");
  for (let i = 0; i < 4; i++) {
    quotaSeed.run(subject, crypto.randomUUID(), digest);
  }
  const competing = await Promise.all(Array.from({ length: 3 }, () => submit(token,
    { generationId: crypto.randomUUID(), prompt: 'Una scheda per annotare libri.' })));
  assert.deepEqual(competing.map(response => response.status).sort(), [200, 429, 429]);
  assert.equal(prompts.length, 6);
  sqlite.prepare(`INSERT INTO web_app_generations (owner_subject, generation_id, prompt_sha256, status, created_at)
    SELECT owner_subject, '00000000-0000-4000-8000-000000000001', prompt_sha256, 'generating', unixepoch()-181
    FROM web_app_generations WHERE generation_id = ?`).run(first.generationId);
  const interrupted = await submit(token, { ...first, generationId: '00000000-0000-4000-8000-000000000001' });
  assert.equal((await interrupted.json()).status, 'interrupted');
  assert.equal(prompts.filter(prompt => prompt === first.prompt).length, 1);
});

test('storage failures and JWKS outages return sanitized errors without mutating project', async () => {
  const signing = await signer();
  const f = d1Fixture();
  const token = await signing.sign();
  const failingKeys = setup(f, signing, 'approve', {
    fetchImpl: async () => { throw Error('private provider credential'); },
  });
  const payload = { projectId, expectedRevision: 1, expectedSpecSha256: digest };
  const unreachable = await failingKeys.handler(webRequest(token, payload));
  assert.equal(unreachable.status, 503);
  assert.deepEqual(await body(unreachable), {
    version: 1, ok: false, error: 'access_unavailable',
  });
  assert.equal(f.prepares, 0);
  f.failDb();
  const gate = setup(f, signing);
  const r = await gate.handler(webRequest(token, payload));
  assert.equal(r.status, 503);
  const json = await body(r);
  assert.equal(json.error, 'storage_unavailable');
  assert.doesNotMatch(JSON.stringify(json), /private|provider|credential|SQL/);
});


test('app generation accepts structured 8000-character and Unicode briefs within the dedicated size gate', async t => {
  const { db, sqlite } = sqliteD1(t, ['006_web_app_generations.sql']);
  const signing = await signer();
  const iat = Math.floor(Date.now() / 1000) - 10;
  const token = await signing.sign({ iat, nbf: iat, exp: iat + 300 });
  const model = '@cf/google/gemma-4-26b-a4b-it';
  let inferenceCalls = 0;
  const env = {
    AIVEXUS_WEB_ORIGIN: origin,
    AIVEXUS_WEB_ACCESS_ISSUER: issuer,
    AIVEXUS_WEB_ACCESS_AUDIENCE: audience,
    AIVEXUS_WEB_D1: db,
    AIVEXUS_WEB_BUILDER_FREE_ENABLED: 'true',
    AIVEXUS_WEB_BUILDER_AI: {
      async run(selectedModel, request) {
        assert.equal(selectedModel, model);
        const brief = request.messages.at(-1).content;
        assert.ok(brief.length >= 8000);
        inferenceCalls++;
        return {
          model,
          choices: [{ finish_reason: 'stop', message: {
            content: JSON.stringify({
              title: 'App da specifica strutturata',
              requirements: ['Mostra una schermata navigabile'],
              files: [{ path: 'index.html', content: '<main>Anteprima</main>' }],
            }),
          } }],
          usage: { completion_tokens: 80 },
        };
      },
    },
  };
  t.mock.method(globalThis, 'fetch', async url => {
    assert.equal(String(url), issuer + '/cdn-cgi/access/certs');
    return Response.json({ keys: [signing.jwk] });
  });
  const send = brief => generateApplication({
    request: webRequest(token, {
      generationId: crypto.randomUUID(), prompt: brief,
    }, { path: '/api/cantiere/proposals/generate' }),
    env,
  });

  // >8 KiB UTF-8 with exactly 8000 visible characters: allowed.
  const structured = 'é'.repeat(8000);
  assert.ok(Buffer.byteLength(JSON.stringify({ generationId: crypto.randomUUID(), prompt: structured })) > 8192);
  const accepted = await send(structured);
  assert.equal(accepted.status, 200);
  assert.equal((await accepted.json()).status, 'generated');
  assert.equal(inferenceCalls, 1);

  // Flutter's maxLength counts grapheme clusters, not JS UTF-16 units.
  const emoji = '🛡️'.repeat(4000);
  const unicodeResponse = await send(emoji);
  assert.equal(unicodeResponse.status, 200);
  assert.equal((await unicodeResponse.json()).status, 'generated');
  assert.equal(inferenceCalls, 2);

  const beyondLimit = await send('x'.repeat(8001));
  assert.equal(beyondLimit.status, 400);
  assert.equal((await beyondLimit.json()).error, 'invalid_request');
  assert.equal(inferenceCalls, 2);

  const excessiveBytes = await send('x'.repeat(55000));
  assert.equal(excessiveBytes.status, 413);
  assert.equal((await excessiveBytes.json()).error, 'request_too_large');
  assert.equal(inferenceCalls, 2);

  const records = sqlite.prepare('SELECT COUNT(*) AS count FROM web_app_generations').get().count;
  assert.equal(records, 2);
});


test('authenticated quota exposes exact personal/global counts and next available slot', async t => {
  const { db, sqlite } = sqliteD1(t, ['006_web_app_generations.sql']);
  const signing = await signer();
  const iat = Math.floor(Date.now() / 1000) - 10;
  const token = await signing.sign({ iat, nbf: iat, exp: iat + 300 });
  const another = await signing.sign({ iat, nbf: iat, exp: iat + 300, sub: 'third-owner' });
  const env = {
    AIVEXUS_WEB_ORIGIN: origin,
    AIVEXUS_WEB_ACCESS_ISSUER: issuer,
    AIVEXUS_WEB_ACCESS_AUDIENCE: audience,
    AIVEXUS_WEB_D1: db,
  };
  t.mock.method(globalThis, 'fetch', async url => {
    assert.equal(String(url), issuer + '/cdn-cgi/access/certs');
    return Response.json({ keys: [signing.jwk] });
  });
  const read = (assertion, path = '/api/cantiere/proposals/quota', method = 'GET') =>
    quotaApplication({
      request: webRequest(assertion, null, {
        path, method, requestOrigin: null,
      }),
      env,
    });

  assert.equal((await read(null)).status, 401);
  assert.equal((await read(token, '/api/cantiere/proposals/quota?foo=bar')).status, 400);
  assert.equal((await read(token, undefined, 'POST')).status, 405);
  const empty = await body(await read(token));
  assert.deepEqual(empty, {
    version: 1, ok: true,
    userLimit: 10, userUsed: 0, userRemaining: 10,
    globalLimit: 72, globalUsed: 0, globalRemaining: 72,
    tier: 'standard',
    remaining: 10, windowSeconds: 86400, nextAvailableAt: null,
    scope: 'aivexus_reservations',
  });

  // Admin role is computed only from signed Cloudflare Access subject and
  // an exact server-side identity setting, not from a browser-provided flag.
  const adminEnv = { ...env, AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT: subject };
  const adminResponse = await quotaApplication({
    request: webRequest(token, null, {
      method: 'GET', path: '/api/cantiere/proposals/quota',
      requestOrigin: null,
    }),
    env: adminEnv,
  });
  const adminQuota = await body(adminResponse);
  assert.equal(adminQuota.tier, 'administrator');
  assert.equal(adminQuota.userLimit, 64);
  assert.equal(adminQuota.globalLimit, 72);
  assert.equal(adminQuota.remaining, 64);
  const nonAdminResponse = await quotaApplication({
    request: webRequest(another, null, {
      method: 'GET', path: '/api/cantiere/proposals/quota',
      requestOrigin: null,
    }),
    env: adminEnv,
  });
  const nonAdminQuota = await body(nonAdminResponse);
  assert.equal(nonAdminQuota.tier, 'standard');
  assert.equal(nonAdminQuota.userLimit, 10);

  // The existing owner can be recognized via email within a *signed*
  // Cloudflare Access JWT; no second admin account and no public whitelist.
  const ownerEmail = 'owner@example.test';
  const signedOwner = await signing.sign({
    iat, nbf: iat, exp: iat + 300,
    email: ownerEmail,
  });
  const signedCustomer = await signing.sign({
    iat, nbf: iat, exp: iat + 300,
    sub: 'customer-subject', email: 'customer@example.test',
  });
  const ownerEmailEnv = { ...env, AIVEXUS_WEB_OWNER_EMAIL: ownerEmail };
  const requestQuota = (assertion, extraHeaders = null) => {
    const request = webRequest(assertion, null, {
      method: 'GET', path: '/api/cantiere/proposals/quota',
      requestOrigin: null,
    });
    if (extraHeaders) {
      for (const [key, value] of Object.entries(extraHeaders)) {
        request.headers.set(key, value);
      }
    }
    return quotaApplication({ request, env: ownerEmailEnv });
  };
  const signedOwnerQuota = await body(await requestQuota(signedOwner));
  assert.equal(signedOwnerQuota.tier, 'administrator');
  assert.equal(signedOwnerQuota.userLimit, 64);
  assert.equal((await body(await requestQuota(signedCustomer))).tier, 'standard');
  // An unsigned email header does NOT grant the customer owner privileges.
  const forgedHeaderQuota = await body(await requestQuota(signedCustomer, {
    'cf-access-authenticated-user-email': ownerEmail,
    'x-aivexus-admin': 'true',
  }));
  assert.equal(forgedHeaderQuota.tier, 'standard');
  assert.equal((await body(await requestQuota(token))).tier, 'standard');
  // A configured owner email takes precedence over an obsolete sub mapping:
  // do not accidentally authorize two separate administrators.
  const staleSubjectEnv = {
    ...ownerEmailEnv, AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT: 'customer-subject',
  };
  const staleRequest = webRequest(signedCustomer, null, {
    method: 'GET', path: '/api/cantiere/proposals/quota',
    requestOrigin: null,
  });
  assert.equal((await body(await quotaApplication({
    request: staleRequest, env: staleSubjectEnv,
  }))).tier, 'standard');
  // Signed emails must match *exactly* after case folding; no domain grants.
  assert.equal(existingWebOwnerSubject({
    principal: { verifiedBy: 'cloudflare-access-jwt',
      subject: 'test', email: 'Customer@Example.Test' },
    configuredEmail: 'example.test',
  }), null);
  assert.equal(existingWebOwnerSubject({
    principal: { verifiedBy: 'untrusted-header',
      subject: 'test', email: ownerEmail },
    configuredEmail: ownerEmail,
  }), null);

  const seed = sqlite.prepare(
    "INSERT INTO web_app_generations (owner_subject, generation_id, prompt_sha256, status, created_at) VALUES (?, ?, ?, 'failed', unixepoch())");
  for (let i = 0; i < 10; i++) seed.run(subject, crypto.randomUUID(), digest);
  for (let i = 0; i < 62; i++) seed.run('other-owner', crypto.randomUUID(), digest);
  const full = await body(await read(token));
  assert.equal(full.userUsed, 10);
  assert.equal(full.globalUsed, 72);
  assert.equal(full.userRemaining, 0);
  assert.equal(full.globalRemaining, 0);
  assert.equal(full.remaining, 0);
  assert.equal(full.scope, 'aivexus_reservations');
  assert.equal(typeof full.nextAvailableAt, 'string');
  const recovery = Date.parse(full.nextAvailableAt);
  assert.ok(recovery > Date.now() + 86000 * 1000);
  assert.ok(recovery <= Date.now() + 86400 * 1000);
  assert.doesNotMatch(JSON.stringify(full), /other-owner|access-subject/);

  const unrelated = await body(await read(another));
  assert.equal(unrelated.userRemaining, 10);
  assert.equal(unrelated.globalRemaining, 0);
  assert.equal(unrelated.remaining, 0);

  // The rolling window clears expired rows without requiring a midnight reset.
  sqlite.prepare(
    'UPDATE web_app_generations SET created_at = unixepoch() - 86401 WHERE owner_subject = ?'
  ).run(subject);
  const partial = await body(await read(token));
  assert.equal(partial.userRemaining, 10);
  assert.equal(partial.globalRemaining, 10);
  assert.equal(partial.remaining, 10);
  assert.equal(partial.nextAvailableAt, null);
});


test('only server-declared Cloudflare Access administrator can generate beyond standard cap', async t => {
  const { db, sqlite } = sqliteD1(t, ['006_web_app_generations.sql']);
  const signing = await signer();
  const iat = Math.floor(Date.now() / 1000) - 10;
  const token = await signing.sign({ iat, nbf: iat, exp: iat + 300 });
  let inferenceCalls = 0;
  const env = {
    AIVEXUS_WEB_ORIGIN: origin,
    AIVEXUS_WEB_ACCESS_ISSUER: issuer,
    AIVEXUS_WEB_ACCESS_AUDIENCE: audience,
    AIVEXUS_WEB_D1: db,
    AIVEXUS_WEB_BUILDER_FREE_ENABLED: 'true',
    AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT: subject,
    AIVEXUS_WEB_BUILDER_AI: {
      async run() {
        inferenceCalls++;
        return {
          model: '@cf/google/gemma-4-26b-a4b-it',
          choices: [{
            finish_reason: 'stop',
            message: { content: JSON.stringify({
              title: 'Admin app',
              requirements: ['Una pagina leggibile'],
              files: [{ path: 'index.html', content: '<main>Admin app</main>' }],
            }) },
          }],
          usage: { completion_tokens: 80 },
        };
      },
    },
  };
  t.mock.method(globalThis, 'fetch', async url => {
    assert.equal(String(url), issuer + '/cdn-cgi/access/certs');
    return Response.json({ keys: [signing.jwk] });
  });
  const seed = sqlite.prepare(
    "INSERT INTO web_app_generations (owner_subject, generation_id, prompt_sha256, status) VALUES (?, ?, ?, 'failed')"
  );
  for (let i = 0; i < 10; i++) {
    seed.run(subject, crypto.randomUUID(), digest);
  }
  const payload = { generationId: crypto.randomUUID(), prompt: 'App semplice con un menu' };
  const send = bindings => generateApplication({
    request: webRequest(token, payload, { path: '/api/cantiere/proposals/generate' }),
    env: bindings,
  });
  // A browser cannot claim the admin identity: it must match a server-side
  // value and the *signed* Access sub.
  assert.equal((await send({ ...env, AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT: undefined })).status, 429);
  assert.equal((await send({ ...env, AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT: 'someone-else' })).status, 429);
  assert.equal(inferenceCalls, 0);
  const accepted = await send(env);
  assert.equal(accepted.status, 200);
  assert.equal((await accepted.json()).status, 'generated');
  assert.equal(inferenceCalls, 1);
  const quotaResponse = await quotaApplication({
    request: webRequest(token, null, {
      method: 'GET', requestOrigin: null, path: '/api/cantiere/proposals/quota',
    }),
    env,
  });
  const quota = await body(quotaResponse);
  assert.equal(quota.tier, 'administrator');
  assert.equal(quota.userUsed, 11);
  assert.equal(quota.userLimit, 64);
  assert.equal(quota.userRemaining, 53);
  assert.equal(quota.globalLimit, 72);
});


test('verified same-owner project reuse does not invoke AI or consume quota', async t => {
  const { db, sqlite } = sqliteD1(t, [
    '006_web_app_generations.sql', '007_web_app_verifications.sql',
  ]);
  const signing = await signer();
  const iat = Math.floor(Date.now() / 1000) - 10;
  const token = await signing.sign({ iat, nbf: iat, exp: iat + 300 });
  const stranger = await signing.sign({
    iat, nbf: iat, exp: iat + 300, sub: 'stranger-subject',
  });
  const env = {
    AIVEXUS_WEB_ORIGIN: origin,
    AIVEXUS_WEB_ACCESS_ISSUER: issuer,
    AIVEXUS_WEB_ACCESS_AUDIENCE: audience,
    AIVEXUS_WEB_D1: db,
  };
  t.mock.method(globalThis, 'fetch', async url => {
    assert.equal(String(url), issuer + '/cdn-cgi/access/certs');
    return Response.json({ keys: [signing.jwk] });
  });
  const promptHash = createHash('sha256').update('App verificata').digest('hex');
  const id = crypto.randomUUID();
  sqlite.prepare(
    "INSERT INTO web_app_generations (owner_subject, generation_id, prompt_sha256, status, result_json) VALUES (?, ?, ?, 'generated', ?)"
  ).run(subject, id, promptHash, JSON.stringify({
    source: { title: 'App verificata', requirements: ['Navigabile'],
      files: [{ path: 'index.html', content: '<main>OK</main>' }] },
    sourceSha256: digest,
    provenance: { reportedModel: '@cf/google/gemma-4-26b-a4b-it' },
    checks: [],
  }));
  const path = '/api/cantiere/proposals/reuse?promptSha256=' + promptHash;
  const read = (assertion, requestPath = path) => reuseApplication({
    request: webRequest(assertion, undefined, {
      method: 'GET', requestOrigin: null, path: requestPath,
    }),
    env,
  });

  assert.equal((await read(null)).status, 401);
  assert.equal((await read(token, '/api/cantiere/proposals/reuse?promptSha256=bad')).status, 400);
  assert.equal((await body(await read(token))).found, false);
  const insertVerified = sqlite.prepare(
    "INSERT INTO web_app_verifications (owner_subject, generation_id, ticket, head_sha, job_sha256, source_sha256, status, run_id, receipt_json, source_json, zip_sha256, zip_bytes) VALUES (?, ?, ?, ?, ?, ?, 'verified', ?, ?, ?, ?, ?)"
  );
  insertVerified.run(
    subject, id, crypto.randomUUID(), 'f'.repeat(40), digest, digest,
    12345, '{}',
    JSON.stringify({ title: 'App verificata', requirements: ['Navigabile'],
      files: [{ path: 'index.html', content: '<main>OK</main>' }] }),
    digest, Buffer.from([0x50, 0x4b, 0x03, 0x04, ...Array(18).fill(0)]),
  );
  const reused = await body(await read(token));
  assert.equal(reused.ok, true);
  assert.equal(reused.found, true);
  assert.equal(reused.generationId, id);
  assert.equal((await body(await read(stranger))).found, false);
  assert.equal((await body(await read(token,
    '/api/cantiere/proposals/reuse?promptSha256=' + '0'.repeat(64)))).found, false);
  assert.equal(sqlite.prepare('SELECT COUNT(*) AS count FROM web_app_generations').get().count, 1);
  assert.equal((await body(await quotaApplication({
    request: webRequest(token, undefined, {
      method: 'GET', requestOrigin: null, path: '/api/cantiere/proposals/quota',
    }),
    env,
  }))).userUsed, 1);
});


test('large NVIDIA trial never spends a generation quota before free-entitlement verification', async () => {
  const id = crypto.randomUUID();
  const trial = {
    id: 'kimi-k26-orchestrator',
    endpoint: 'https://integrate.api.nvidia.com/v1/chat/completions',
    model: 'moonshotai/kimi-k2.6',
    apiKeySecret: 'AIVEXUS_NIM_TEST_KEY',
    selfTestFree: true,
    manualOnly: true,
    builderFreeVerified: true,
  };
  const env = {
    AIVEXUS_WEB_BUILDER_AI: { run: async () => {
      throw new Error('Cloudflare builder must never be called');
    } },
    AIVEXUS_WEB_BUILDER_FREE_ENABLED: 'true',
    CANTIERE_CLOUD_ROUTES_JSON: JSON.stringify({ orchestration: [trial] }),
    AIVEXUS_NIM_TEST_KEY: 'dummy-credential',
  };
  const infer = createWebBuilderInference(env);
  let reads = 0;
  let writes = 0;
  const db = {
    prepare(query) {
      return {
        bind() {
          return {
            async first() {
              if (query.includes('SELECT CASE WHEN status')) {
                reads++;
                return null;
              }
              writes++;
              throw new Error('D1 reservation must not occur for unapproved trial');
            },
          };
        },
      };
    },
  };
  const request = {
    generationId: id,
    prompt: 'Crea una piccola app con due pulsanti',
    builderRouteId: trial.id,
  };
  const blocked = await generateWebApplication({
    request, ownerSubject: 'signed-user', db, infer,
  });
  assert.deepEqual(blocked, { ok: false, reason: 'generation_model_unavailable' });
  assert.equal(reads, 1);
  assert.equal(writes, 0);
  assert.equal(listWebBuilderLargeModels(env).find(r => r.routeId === trial.id).available, false);

  // A synthetic self-test being free is insufficient for a full builder job.
  env.AIVEXUS_WEB_BUILDER_NIM_FREE_VERIFIED = 'true';
  const routeNotApproved = createWebBuilderInference(env);
  assert.equal(routeNotApproved.supportsBuilderRoute(trial.id), true);
  const normalUserDenied = await generateWebApplication({
    request, ownerSubject: 'signed-user',
    adminSubject: 'different-signed-admin',
    db, infer: routeNotApproved,
  });
  assert.deepEqual(normalUserDenied,
    { ok: false, reason: 'generation_model_unavailable' });
  assert.equal(writes, 0);
  delete trial.builderFreeVerified;
  env.CANTIERE_CLOUD_ROUTES_JSON = JSON.stringify({ orchestration: [trial] });
  assert.equal(createWebBuilderInference(env).supportsBuilderRoute(trial.id), false);

  // No arbitrary paid or mismatched model is eligible.
  trial.builderFreeVerified = true;
  trial.endpoint = 'https://example.com/paid/completions';
  env.CANTIERE_CLOUD_ROUTES_JSON = JSON.stringify({ orchestration: [trial] });
  assert.equal(createWebBuilderInference(env).supportsBuilderRoute(trial.id), false);
  trial.endpoint = 'https://integrate.api.nvidia.com/v1/chat/completions';
  trial.model = 'unapproved/giant-model';
  env.CANTIERE_CLOUD_ROUTES_JSON = JSON.stringify({ orchestration: [trial] });
  assert.equal(createWebBuilderInference(env).supportsBuilderRoute(trial.id), false);
});

test('free-verified NVIDIA 1T builder uses exactly one trial request and reports provenance', async t => {
  const model = 'moonshotai/kimi-k2.6';
  const endpoint = 'https://integrate.api.nvidia.com/v1/chat/completions';
  const trial = {
    id: 'kimi-k26-orchestrator',
    model,
    endpoint,
    apiKeySecret: 'AIVEXUS_NIM_TEST_KEY',
    selfTestFree: true,
    manualOnly: true,
    builderFreeVerified: true,
  };
  const env = {
    CANTIERE_CLOUD_ROUTES_JSON: JSON.stringify({ orchestration: [trial] }),
    AIVEXUS_NIM_TEST_KEY: 'placeholder-test-only',
    AIVEXUS_WEB_BUILDER_NIM_FREE_VERIFIED: 'true',
  };
  const infer = createWebBuilderInference(env);
  assert.ok(infer);
  assert.equal(infer.supportsBuilderRoute(trial.id), true);
  assert.equal(infer.supportsBuilderRoute('other-paid-provider'), false);
  assert.equal(listWebBuilderLargeModels(env).find(r => r.routeId === trial.id).available, true);
  let calls = 0;
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    calls++;
    assert.equal(String(url), endpoint);
    assert.equal(options.method, 'POST');
    const request = JSON.parse(options.body);
    assert.equal(request.model, model);
    assert.equal(request.max_tokens, 4096);
    assert.equal(request.stream, false);
    assert.equal(request.messages.at(-1).role, 'user');
    return new Response(JSON.stringify({
      model, choices: [{
        finish_reason: 'stop',
        message: { content: JSON.stringify({
          title: 'Contatore NVIDIA',
          requirements: ['Un pulsante incrementa il conteggio'],
          files: [{ path: 'index.html', content: '<button id="count">0</button>' }],
          checks: [{ action: 'text', selector: '#count', value: '0' }],
        }) },
      }],
      usage: { completion_tokens: 100 },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  });
  const result = await infer([
    { role: 'system', content: 'Return a single JSON object.' },
    { role: 'user', content: 'Crea contatore.' },
  ], trial.id);
  assert.equal(result.ok, true);
  assert.equal(result.model, model);
  assert.equal(result.reportedModel, model);
  assert.equal(result.provider, 'NVIDIA NIM');
  assert.equal(result.routeId, trial.id);
  assert.equal(calls, 1);
});
