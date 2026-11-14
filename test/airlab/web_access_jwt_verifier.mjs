import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyCloudflareAccessAssertion as verify } from
  '../../scripts/web/cloudflare_access_jwt_verifier.mjs';

const issuer = 'https://aivexus-example.cloudflareaccess.com';
const audience = 'aivexus-web-private-application-aud';
const nowSeconds = 1794660000;

async function fixture() {
  // Locally generated ephemeral key only. No Cloudflare credentials or calls.
  const keys = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true, ['sign', 'verify']
  );
  const pub = await crypto.subtle.exportKey('jwk', keys.publicKey);
  const jwks = { keys: [{ ...pub, kid: 'test-key-1', alg: 'RS256', use: 'sig' }] };
  function enc(value) {
    return Buffer.from(JSON.stringify(value)).toString('base64url');
  }
  async function sign({
    header = { alg: 'RS256', typ: 'JWT', kid: 'test-key-1' },
    payload = { iss: issuer, aud: [audience], sub: 'test-access-subject',
      iat: nowSeconds - 100, nbf: nowSeconds - 100,
      exp: nowSeconds + 600 },
  } = {}) {
    const data = enc(header) + '.' + enc(payload);
    const signature = await crypto.subtle.sign(
      { name: 'RSASSA-PKCS1-v1_5' }, keys.privateKey,
      new TextEncoder().encode(data)
    );
    return data + '.' + Buffer.from(signature).toString('base64url');
  }
  async function call(token, opts = {}) {
    return verify({
      assertion: token, expectedIssuer: issuer,
      expectedAudience: audience, jwks, nowSeconds, ...opts,
    });
  }
  return { jwks, sign, call };
}

test('valid signed RS256 Access JWT creates an internal subject-only principal', async () => {
  const f = await fixture();
  const token = await f.sign();
  const result = await f.call(token);
  assert.deepEqual(result, {
    ok: true,
    principal: { subject: 'test-access-subject', verifiedBy: 'cloudflare-access-jwt' },
  });
  assert.doesNotMatch(JSON.stringify(result), /signature|token|email|aud/);
});

test('wrong app audience or issuer fails with a generic response', async () => {
  const f = await fixture();
  for (const payload of [
    { iss: issuer, aud: 'another-app', sub: 's', exp: nowSeconds + 1 },
    { iss: 'https://evil.cloudflareaccess.com', aud: [audience],
      sub: 's', exp: nowSeconds + 1 },
  ]) {
    const token = await f.sign({ payload });
    assert.deepEqual(await f.call(token), { ok: false, reason: 'invalid_access_assertion' });
  }
  const token = await f.sign();
  assert.equal((await f.call(token, { expectedAudience: 'another-app' })).ok, false);
  assert.equal((await f.call(token, { expectedIssuer: 'https://evil.example' })).reason,
    'invalid_access_configuration');
});

test('expired, future nbf/iat, missing subject and malformed claims fail', async () => {
  const f = await fixture();
  const cases = [
    { iss: issuer, aud: audience, sub: 's', exp: nowSeconds },
    { iss: issuer, aud: audience, sub: 's', exp: nowSeconds + 5,
      nbf: nowSeconds + 1 },
    { iss: issuer, aud: audience, sub: 's', exp: nowSeconds + 5,
      iat: nowSeconds + 1 },
    { iss: issuer, aud: audience, sub: 's', exp: nowSeconds + 5,
      iat: nowSeconds + 6 },
    { iss: issuer, aud: audience, sub: '', exp: nowSeconds + 5 },
    { iss: issuer, aud: audience, exp: nowSeconds + 5 },
    { iss: issuer, aud: [{ app: audience }], sub: 's', exp: nowSeconds + 5 },
    { iss: issuer, aud: audience, sub: 's', exp: 'future' },
  ];
  for (const payload of cases) {
    const token = await f.sign({ payload });
    assert.deepEqual(await f.call(token), { ok: false, reason: 'invalid_access_assertion' });
  }
});

test('tampering with signed claim, alg none/HS256 or malformed JWT fails', async () => {
  const f = await fixture();
  const valid = await f.sign();
  const [header, body, sig] = valid.split('.');
  const forged = Buffer.from(JSON.stringify({
    iss: issuer, aud: audience, sub: 'attacker', exp: nowSeconds + 100,
  })).toString('base64url');
  for (const token of [
    [header, forged, sig].join('.'),
    (await f.sign({ header: { alg: 'none', kid: 'test-key-1' } })),
    (await f.sign({ header: { alg: 'HS256', kid: 'test-key-1' } })),
    [header, body, 'broken'].join('.'),
    'garbage', valid + '.extra', 'x'.repeat(17000),
    [header, body, sig + '='].join('.'),
    ['', body, sig].join('.'),
  ]) {
    assert.equal((await f.call(token)).ok, false);
  }
});

test('unmatched, duplicate, untrusted or undersized RSA JWK fails closed', async () => {
  const f = await fixture();
  const token = await f.sign();
  for (const jwks of [
    { keys: [] },
    { keys: [f.jwks.keys[0], f.jwks.keys[0]] },
    { keys: [{ ...f.jwks.keys[0], kty: 'oct' }] },
    { keys: [{ ...f.jwks.keys[0], kid: 'different' }] },
    { keys: [{ ...f.jwks.keys[0], n: 'AQAB' }] },
    { keys: [{ ...f.jwks.keys[0], use: 'enc' }] },
    null,
  ]) {
    const result = await f.call(token, { jwks });
    assert.deepEqual(result, { ok: false, reason: 'untrusted_access_keys' });
  }
});

test('config and absent credential fail closed; no fallback to browser identity', async () => {
  const f = await fixture();
  const token = await f.sign();
  assert.equal((await f.call(null)).ok, false);
  assert.equal((await f.call(token, { expectedIssuer: 'http://team.cloudflareaccess.com' }))
    .reason, 'invalid_access_configuration');
  assert.equal((await f.call(token, { expectedAudience: '' })).reason,
    'invalid_access_configuration');
  assert.equal((await f.call(token, { nowSeconds: 'client-time' })).reason,
    'invalid_access_configuration');
});
