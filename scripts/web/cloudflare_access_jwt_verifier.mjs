// AIVEXUS Web-only Cloudflare Access JWT verifier (SOURCE-ONLY).
// No Pages Function imports this module; no Access secrets, D1 or deployment.
// The eventual HTTP adapter MUST read Cf-Access-Jwt-Assertion from the
// request at a protected origin, and pass issuer/audience/JWKS from trusted
// server-side configuration. Never accept those settings from request JSON.
// The returned principal is for INTERNAL server use; never echo it to clients.

const B64URL = /^[A-Za-z0-9_-]+$/;
const CF_ISSUER = /^https:\/\/[a-z0-9-]+\.cloudflareaccess\.com$/;
const MAX_TOKEN_BYTES = 16384;
const MAX_JSON_BYTES = 8192;

function fail(reason = 'invalid_access_assertion') {
  return { ok: false, reason };
}

function decodeB64url(text, maxBytes) {
  if (typeof text !== 'string' || text.length === 0 ||
      text.length > Math.ceil(maxBytes * 4 / 3) + 4 ||
      !B64URL.test(text) || text.length % 4 === 1) return null;
  try {
    const normalized = text.replace(/-/g, '+').replace(/_/g, '/');
    const bytes = Uint8Array.from(
      atob(normalized + '='.repeat((4 - text.length % 4) % 4)),
      char => char.charCodeAt(0)
    );
    return bytes.length <= maxBytes ? bytes : null;
  } catch (_) {
    return null;
  }
}

function parseSegment(segment) {
  const bytes = decodeB64url(segment, MAX_JSON_BYTES);
  if (!bytes) return null;
  try {
    // Reject malformed UTF-8 rather than silently normalizing token claims.
    const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch (_) {
    return null;
  }
}

function validJwkKey(jwk, kid) {
  if (!jwk || typeof jwk !== 'object' || Array.isArray(jwk) ||
      jwk.kid !== kid || jwk.kty !== 'RSA' ||
      (jwk.alg !== undefined && jwk.alg !== 'RS256') ||
      (jwk.use !== undefined && jwk.use !== 'sig') ||
      (jwk.key_ops !== undefined && (!Array.isArray(jwk.key_ops) ||
        !jwk.key_ops.includes('verify'))) ||
      !decodeB64url(jwk.e, 8)) return false;
  const modulus = decodeB64url(jwk.n, 1024);
  return modulus !== null && modulus.length >= 256 && modulus.length <= 1024;
}

/**
 * Verify an RS256 assertion against an exact trusted Cloudflare Access issuer,
 * application AUD and server-provided JWKS. Does NOT fetch a JWKS or authenticate
 * a caller merely based on a header/marker; cryptographic verification is mandatory.
 *
 * nowSeconds is an injectable trusted SERVER clock, primarily for unit tests.
 */
export async function verifyCloudflareAccessAssertion({
  assertion, expectedIssuer, expectedAudience, jwks,
  nowSeconds = Math.floor(Date.now() / 1000),
} = {}) {
  if (typeof expectedIssuer !== 'string' || !CF_ISSUER.test(expectedIssuer) ||
      typeof expectedAudience !== 'string' ||
      !expectedAudience.trim() || expectedAudience.length > 512 ||
      !Number.isSafeInteger(nowSeconds) || nowSeconds <= 0) {
    return fail('invalid_access_configuration');
  }
  if (typeof assertion !== 'string' || !assertion ||
      assertion.length > MAX_TOKEN_BYTES) return fail();
  const parts = assertion.split('.');
  if (parts.length !== 3) return fail();
  const header = parseSegment(parts[0]);
  const payload = parseSegment(parts[1]);
  const signature = decodeB64url(parts[2], 1024);
  if (!header || !payload || !signature ||
      header.alg !== 'RS256' ||
      (header.typ !== undefined && header.typ !== 'JWT') ||
      typeof header.kid !== 'string' ||
      header.kid.length < 1 || header.kid.length > 128) return fail();
  if (payload.iss !== expectedIssuer ||
      (typeof payload.aud !== 'string' && !Array.isArray(payload.aud)) ||
      !(typeof payload.aud === 'string'
        ? payload.aud === expectedAudience
        : payload.aud.includes(expectedAudience)) ||
      !Number.isSafeInteger(payload.exp) || payload.exp <= nowSeconds ||
      (payload.nbf !== undefined &&
        (!Number.isSafeInteger(payload.nbf) || payload.nbf > nowSeconds)) ||
      (payload.iat !== undefined &&
        (!Number.isSafeInteger(payload.iat) || payload.iat > nowSeconds ||
          payload.iat > payload.exp)) ||
      typeof payload.sub !== 'string' || !payload.sub.trim() ||
      payload.sub.length > 256) return fail();
  if (!jwks || !Array.isArray(jwks.keys) || jwks.keys.length > 64) {
    return fail('untrusted_access_keys');
  }
  const keys = jwks.keys.filter(key => key?.kid === header.kid);
  if (keys.length !== 1 || !validJwkKey(keys[0], header.kid)) {
    return fail('untrusted_access_keys');
  }
  try {
    const key = await crypto.subtle.importKey('jwk', {
      kty: 'RSA', n: keys[0].n, e: keys[0].e, alg: 'RS256', ext: true,
      key_ops: ['verify']
    }, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
    const valid = await crypto.subtle.verify(
      { name: 'RSASSA-PKCS1-v1_5' }, key, signature,
      new TextEncoder().encode(parts[0] + '.' + parts[1])
    );
    if (!valid) return fail();
  } catch (_) {
    return fail('untrusted_access_keys');
  }
  return {
    ok: true,
    // INTERNAL only: pass straight to Web D1 approval/reservation modules.
    principal: { subject: payload.sub, verifiedBy: 'cloudflare-access-jwt' },
  };
}
