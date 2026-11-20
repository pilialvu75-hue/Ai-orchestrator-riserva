import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { createWebCustomerAccessHandler, activeWebCustomerGrant } from
  '../../scripts/web/web_client_invitations.mjs';
import { createAuthenticatedWebProjectOperation } from
  '../../scripts/web/authenticated_web_project_operation.mjs';

const issuer = 'https://aivexus-test.cloudflareaccess.com';
const audience = 'private-web-client';
const origin = 'https://aivexus.pages.dev';

function fixture() {
  const sqlite = new DatabaseSync(':memory:');
  for (const file of ['006_web_app_generations.sql', '008_web_client_invitations.sql']) {
    sqlite.exec(readFileSync('scripts/web/sql/' + file, 'utf8'));
  }
  const db = {
    prepare(query) {
      const statement = sqlite.prepare(query);
      return {
        bind(...params) {
          return {
            async first() { return statement.get(...params) ?? null; },
            async all() { return { results: statement.all(...params) }; },
            async run() { return { meta: statement.run(...params) }; },
          };
        },
      };
    },
  };
  return { db, sqlite };
}

async function signedAccess() {
  const keys = await crypto.subtle.generateKey({
    name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256',
  }, true, ['sign', 'verify']);
  const jwk = { ...await crypto.subtle.exportKey('jwk', keys.publicKey),
    kid: 'customer-test-key', alg: 'RS256', use: 'sig' };
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  async function sign({ sub, email }) {
    const now = Math.floor(Date.now() / 1000);
    const head = encode({ alg: 'RS256', typ: 'JWT', kid: jwk.kid });
    const payload = encode({ iss: issuer, aud: [audience], sub, email,
      iat: now - 10, nbf: now - 10, exp: now + 3600 });
    const data = head + '.' + payload;
    const signature = await crypto.subtle.sign({
      name: 'RSASSA-PKCS1-v1_5',
    }, keys.privateKey, new TextEncoder().encode(data));
    return data + '.' + Buffer.from(signature).toString('base64url');
  }
  const fetchImpl = async url => {
    assert.equal(url, issuer + '/cdn-cgi/access/certs');
    return Response.json({ keys: [jwk] });
  };
  return { sign, fetchImpl };
}

function request({ token, path, method = 'GET', body, headers = {} }) {
  return new Request(origin + path, {
    method,
    headers: {
      ...(token ? { 'cf-access-jwt-assertion': token } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(method !== 'GET' ? { Origin: origin } : {}),
      ...headers,
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}
const parse = async r => ({ http: r.status, ...(await r.json()) });

test('existing owner creates/list/revokes invitations; invited Access client is scoped', async () => {
  const { db, sqlite } = fixture();
  const auth = await signedAccess();
  const owner = await auth.sign({ sub: 'owner-subject', email: 'owner@example.test' });
  const alice = await auth.sign({ sub: 'alice-sub', email: 'alice@example.test' });
  const wrong = await auth.sign({ sub: 'wrong-sub', email: 'other@example.test' });
  const opts = {
    db, accessIssuer: issuer, accessAudience: audience, expectedOrigin: origin,
    configuredOwnerSubject: 'owner-subject',
    configuredOwnerEmail: 'owner@example.test',
    fetchImpl: auth.fetchImpl, clientAccessEnabled: true,
  };
  const call = (op, token, method = 'GET', body, headers) =>
    createWebCustomerAccessHandler({ ...opts, operation: op })(request({
      token, path: '/api/cantiere/access/' + op, method, body, headers,
    }));
  assert.equal((await call('create', null, 'POST', {
    email: 'alice@example.test', expiresDays: 3,
  })).status, 401);
  assert.equal((await call('create', alice, 'POST', {
    email: 'alice@example.test', expiresDays: 3,
  })).status, 403);
  const created = await parse(await call('create', owner, 'POST', {
    email: 'Alice@Example.Test', expiresDays: 3,
  }));
  assert.equal(created.http, 200);
  assert.equal(created.ok, true);
  assert.equal(created.status, 'pending');
  assert.equal(created.recipientEmail, 'alice@example.test');
  assert.match(created.invitationId, /^[a-f0-9-]{36}$/);
  const duplicated = await parse(await call('create', owner, 'POST', {
    email: 'alice@example.test', expiresDays: 3,
  }));
  assert.equal(duplicated.http, 409);
  assert.equal((await call('list', alice)).status, 403);
  const listing = await parse(await call('list', owner));
  assert.equal(listing.invitations.length, 1);
  assert.equal(listing.invitations[0].linked, false);

  // Even a caller with the UUID cannot substitute an unsigned email header.
  const stolen = await parse(await call('claim', wrong, 'POST',
    { invitationId: created.invitationId },
    { 'cf-access-authenticated-user-email': 'alice@example.test' }));
  assert.equal(stolen.http, 404);
  assert.equal((await call('claim', alice, 'POST', { invitationId: 'bad' })).status, 400);
  assert.equal((await call('status', alice)).status, 200);
  const before = await parse(await call('status', alice));
  assert.equal(before.role, 'uninvited');
  assert.equal(before.canUseStudio, false);

  const claimed = await parse(await call('claim', alice, 'POST', {
    invitationId: created.invitationId,
  }));
  assert.equal(claimed.http, 200);
  assert.equal(claimed.status, 'accepted');
  assert.equal((await call('claim', alice, 'POST', {
    invitationId: created.invitationId,
  })).status, 404);
  assert.equal((await parse(await call('status', alice))).role, 'client');
  assert.equal((await parse(await call('status', alice))).canUseStudio, true);
  assert.equal((await parse(await call('status', owner))).role, 'owner');
  assert.equal((await parse(await call('status', owner))).canUseStudio, true);
  assert.equal((await parse(await call('status', wrong))).role, 'uninvited');

  const gate = createAuthenticatedWebProjectOperation({
    operation: 'generation_quota', expectedOrigin: origin,
    accessIssuer: issuer, accessAudience: audience,
    adminSubject: 'owner-subject', ownerEmail: 'owner@example.test',
    clientAccessEnabled: true, fetchImpl: auth.fetchImpl, db,
  });
  const quotaRequest = token => request({
    token, path: '/api/cantiere/proposals/quota',
  });
  assert.equal((await gate(quotaRequest(wrong))).status, 403);
  const aliceQuota = await parse(await gate(quotaRequest(alice)));
  assert.equal(aliceQuota.http, 200);
  assert.equal(aliceQuota.tier, 'standard');
  assert.equal(aliceQuota.userLimit, 10);
  const ownerQuota = await parse(await gate(quotaRequest(owner)));
  assert.equal(ownerQuota.tier, 'administrator');
  assert.equal(ownerQuota.userLimit, 64);

  assert.equal((await call('revoke', alice, 'POST', {
    invitationId: created.invitationId,
  })).status, 403);
  assert.equal((await call('revoke', owner, 'POST', {
    invitationId: created.invitationId,
  })).status, 200);
  assert.equal((await gate(quotaRequest(alice))).status, 403);
  assert.equal(await activeWebCustomerGrant({
    db, principal: { verifiedBy: 'cloudflare-access-jwt',
      subject: 'alice-sub', email: 'alice@example.test' },
  }), false);
  assert.equal(sqlite.prepare(
    "SELECT status FROM web_client_invitations WHERE invitation_id = ?"
  ).get(created.invitationId).status, 'revoked');
  sqlite.close();
});

test('expired and spoofed invites never authorize access; flags default closed', async () => {
  const { db, sqlite } = fixture();
  const auth = await signedAccess();
  const owner = await auth.sign({ sub: 'owner-subject', email: 'owner@example.test' });
  const alice = await auth.sign({ sub: 'alice-sub', email: 'alice@example.test' });
  const opts = { db, accessIssuer: issuer, accessAudience: audience,
    expectedOrigin: origin, configuredOwnerSubject: 'owner-subject',
    fetchImpl: auth.fetchImpl };
  const handler = operation => createWebCustomerAccessHandler({
    ...opts, operation, clientAccessEnabled: false,
  });
  const created = await parse(await handler('create')(request({
    token: owner, path: '/api/cantiere/access/invitations',
    method: 'POST', body: { email: 'alice@example.test', expiresDays: 1 },
  })));
  assert.equal(created.http, 200);
  sqlite.prepare('UPDATE web_client_invitations SET expires_at = unixepoch() - 1 WHERE invitation_id = ?')
    .run(created.invitationId);
  const expired = await handler('claim')(request({
    token: alice, path: '/api/cantiere/access/claim', method: 'POST',
    body: { invitationId: created.invitationId },
  }));
  assert.equal(expired.status, 404);
  assert.equal((await parse(await handler('status')(request({
    token: alice, path: '/api/cantiere/access/status',
  })))).canUseStudio, false);
  const fakeAdmin = await handler('create')(request({
    token: alice, path: '/api/cantiere/access/invitations',
    method: 'POST', body: { email: 'alice@example.test', expiresDays: 3,
      role: 'owner' },
  }));
  assert.equal(fakeAdmin.status, 403);
  const noCsrf = await handler('create')(new Request(
    origin + '/api/cantiere/access/invitations', {
      method: 'POST', headers: {
        'cf-access-jwt-assertion': owner,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ email: 'bob@example.test', expiresDays: 3 }),
    }));
  assert.equal(noCsrf.status, 403);
  sqlite.close();
});
