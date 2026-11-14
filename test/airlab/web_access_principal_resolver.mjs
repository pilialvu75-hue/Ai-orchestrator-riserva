import test from 'node:test';
import assert from 'node:assert/strict';
import { createCloudflareAccessPrincipalResolver as createResolver } from
  '../../scripts/web/cloudflare_access_principal_resolver.mjs';

const issuer = 'https://aivexus-test.cloudflareaccess.com';
const audience = 'test-aivexus-web-application-aud';
const certsUrl = issuer + '/cdn-cgi/access/certs';
const start = 1794660000;

async function signer(kid = 'kid-one') {
  const keys = await crypto.subtle.generateKey({
    name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256',
  }, true, ['sign', 'verify']);
  const publicKey = await crypto.subtle.exportKey('jwk', keys.publicKey);
  const jwk = { ...publicKey, kid, alg: 'RS256', use: 'sig' };
  async function token(payload = {}, header = {}) {
    const enc = value => Buffer.from(JSON.stringify(value)).toString('base64url');
    const data = enc({ alg: 'RS256', typ: 'JWT', kid, ...header }) +
      '.' + enc({
        iss: issuer, aud: [audience], sub: 'verified-test-owner',
        nbf: start - 100, iat: start - 100, exp: start + 600,
        ...payload,
      });
    const signature = await crypto.subtle.sign(
      { name: 'RSASSA-PKCS1-v1_5' }, keys.privateKey,
      new TextEncoder().encode(data),
    );
    return data + '.' + Buffer.from(signature).toString('base64url');
  }
  return { jwk, token };
}

function jsonResponse(value, status = 200, type = 'application/json') {
  return new Response(typeof value === 'string' ? value : JSON.stringify(value), {
    status, headers: { 'Content-Type': type },
  });
}

function accessRequest(assertion, cookie = '') {
  const headers = new Headers();
  if (assertion !== null) headers.set('Cf-Access-Jwt-Assertion', assertion);
  if (cookie) headers.set('Cookie', cookie);
  return new Request('https://aivexus.pages.dev/api/cantiere/execute', {
    method: 'POST', headers,
  });
}

function setup(fetchImpl, nowSeconds = () => start, extra = {}) {
  return createResolver({
    expectedIssuer: issuer, expectedAudience: audience,
    fetchImpl, nowSeconds, ...extra,
  });
}

test('valid signed assertion is verified from header and pinned issuer JWKS', async () => {
  const signing = await signer();
  let requests = 0;
  const resolver = setup(async (url, init) => {
    requests++;
    assert.equal(url, certsUrl);
    assert.equal(init.method, 'GET');
    assert.equal(init.redirect, 'error');
    assert.equal(init.credentials, 'omit');
    assert.equal(init.cache, 'no-store');
    assert.equal(init.headers.Accept, 'application/json');
    assert.equal(init.signal.aborted, false);
    return jsonResponse({ keys: [signing.jwk] });
  });
  const signed = await signing.token();
  const r = await resolver.resolve(accessRequest(signed));
  assert.deepEqual(r, {
    ok: true, principal: {
      subject: 'verified-test-owner', verifiedBy: 'cloudflare-access-jwt',
    },
  });
  assert.doesNotMatch(JSON.stringify(r), /email|secret|signature|JWT|Cookie/);
  assert.equal(requests, 1);
  assert.deepEqual(await resolver.resolve(accessRequest(signed)), r);
  assert.equal(requests, 1);
});

test('no Access assertion, malformed header and forged cookie never fetch keys', async () => {
  let calls = 0;
  const resolver = setup(async () => { calls++; throw Error('must not fetch'); });
  for (const request of [
    accessRequest(null, 'CF_Authorization=fake'),
    accessRequest(''),
    accessRequest('owner=forged;verifiedBy=cloudflare-access-jwt'),
    accessRequest('a.b.c.d'),
    accessRequest('x'.repeat(18000)),
  ]) {
    assert.deepEqual(await resolver.resolve(request),
      { ok: false, reason: 'access_assertion_required' });
  }
  assert.equal(calls, 0);
});

test('wrong audience, wrong issuer and tampered signature fail closed', async () => {
  const signing = await signer();
  const resolver = setup(async () => jsonResponse({ keys: [signing.jwk] }));
  const good = await signing.token();
  const badTokens = [
    await signing.token({ aud: ['another-application'] }),
    await signing.token({ iss: 'https://evil.cloudflareaccess.com' }),
    await signing.token({ exp: start - 1 }),
    good.slice(0, -4) + 'AAAA',
  ];
  for (const token of badTokens) {
    const r = await resolver.resolve(accessRequest(token));
    assert.deepEqual(r, { ok: false, reason: 'invalid_access_assertion' });
  }
});

test('cached JWKS expire and are fetched again without untrusted fallback', async () => {
  const signing = await signer();
  let now = start;
  let reads = 0;
  const resolver = setup(async () => {
    reads++;
    if (reads === 2) throw Error('simulated network outage');
    return jsonResponse({ keys: [signing.jwk] });
  }, () => now, { cacheTtlSeconds: 30 });
  const request = accessRequest(await signing.token());
  assert.equal((await resolver.resolve(request)).ok, true);
  now += 20;
  assert.equal((await resolver.resolve(request)).ok, true);
  assert.equal(reads, 1);
  now += 11;
  assert.deepEqual(await resolver.resolve(request),
    { ok: false, reason: 'access_keys_unavailable' });
  assert.equal(reads, 2);
  assert.equal((await resolver.resolve(request)).ok, true);
  assert.equal(reads, 3);
});

test('key rotation refreshes pinned issuer once and validates new signer', async () => {
  const oldKey = await signer('old-key');
  const newKey = await signer('new-key');
  let reads = 0;
  const resolver = setup(async () => {
    reads++;
    return jsonResponse({ keys: [reads === 1 ? oldKey.jwk : newKey.jwk] });
  });
  assert.equal((await resolver.resolve(accessRequest(await oldKey.token()))).ok, true);
  assert.equal((await resolver.resolve(accessRequest(await newKey.token()))).ok, true);
  assert.equal(reads, 2);
});

test('unknown kid does not cause unbounded remote JWKS refreshes', async () => {
  const known = await signer('known');
  const forged = await signer('forged-kid');
  let reads = 0;
  const resolver = setup(async () => {
    reads++;
    return jsonResponse({ keys: [known.jwk] });
  });
  const request = accessRequest(await forged.token());
  assert.deepEqual(await resolver.resolve(request),
    { ok: false, reason: 'invalid_access_assertion' });
  for (let i = 0; i < 8; ++i) {
    assert.equal((await resolver.resolve(request)).ok, false);
  }
  assert.equal(reads, 2);
});

test('simultaneous requests use a single remote JWKS fetch', async () => {
  const signing = await signer();
  let calls = 0;
  const resolver = setup(async () => {
    calls++;
    await Promise.resolve();
    return jsonResponse({ keys: [signing.jwk] });
  });
  const req = accessRequest(await signing.token());
  const results = await Promise.all(Array.from({ length: 20 },
    () => resolver.resolve(req)));
  assert.equal(results.every(x => x.ok === true), true);
  assert.equal(calls, 1);
});

test('redirect, bad status, wrong origin, invalid JSON and oversized JWKS fail closed', async () => {
  const signing = await signer();
  const request = accessRequest(await signing.token());
  const responses = [
    () => new Response(null, { status: 302, headers: { Location: 'https://evil.test' } }),
    () => jsonResponse({ keys: [signing.jwk] }, 503),
    () => jsonResponse('<html>login</html>', 200, 'text/html'),
    () => jsonResponse('not json'),
    () => jsonResponse({ keys: [signing.jwk, signing.jwk] }),
    () => jsonResponse('x'.repeat(33000)),
    () => {
      const response = jsonResponse({ keys: [signing.jwk] });
      Object.defineProperty(response, 'url', { value: 'https://evil.test/keys' });
      return response;
    },
  ];
  for (const makeResponse of responses) {
    const resolver = setup(async () => makeResponse());
    assert.deepEqual(await resolver.resolve(request),
      { ok: false, reason: 'access_keys_unavailable' });
  }
  const resolver = setup(async () => { throw Error('internal fetch secret'); });
  const r = await resolver.resolve(request);
  assert.deepEqual(r, { ok: false, reason: 'access_keys_unavailable' });
  assert.doesNotMatch(JSON.stringify(r), /secret|internal/);
});

test('invalid server issuer, audience and cache policy never fetch', async () => {
  const signing = await signer();
  const request = accessRequest(await signing.token());
  let calls = 0;
  const fetchImpl = async () => {
    calls++;
    return jsonResponse({ keys: [signing.jwk] });
  };
  for (const extra of [
    { expectedIssuer: 'https://evil.test' },
    { expectedIssuer: issuer + '/unexpected/path' },
    { expectedAudience: '' },
    { cacheTtlSeconds: 86400 },
    { timeoutMs: 0 },
  ]) {
    const resolver = setup(fetchImpl, () => start, extra);
    assert.deepEqual(await resolver.resolve(request),
      { ok: false, reason: 'invalid_access_configuration' });
  }
  assert.equal(calls, 0);
});
