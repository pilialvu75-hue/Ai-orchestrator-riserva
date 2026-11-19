import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest as reserveExecution } from
  '../../functions/api/cantiere/executions/reserve.js';
import { createAuthenticatedWebProjectOperation } from
  '../../scripts/web/authenticated_web_project_operation.mjs';

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
      assert.equal(init.redirect, 'error');
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

test('Pages reservation route uses server bindings and preserves ownership and idempotency', async t => {
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
