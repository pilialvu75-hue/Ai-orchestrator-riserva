// AIVEXUS Web-only Cloudflare Access assertion -> trusted principal adapter.
// SOURCE-ONLY: no Pages Function imports this module and no production resources
// are configured by it. Call only from a server-side, Access-protected handler.
// expectedIssuer and expectedAudience MUST originate from trusted server config.
// Never pass browser JSON, cookies, or user-controlled URL as these settings.
import { verifyCloudflareAccessAssertion } from './cloudflare_access_jwt_verifier.mjs';

const ISSUER = /^https:\/\/[a-z0-9-]+\.cloudflareaccess\.com$/;
const JWT_SHAPE = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
const MAX_JWKS_BYTES = 32768;
const MAX_ASSERTION_BYTES = 16384;

function failure(reason) {
  return { ok: false, reason };
}

async function readBoundedJson(response) {
  if (!response || response.status !== 200 || !response.ok ||
      response.redirected || !response.body ||
      typeof response.body.getReader !== 'function') return null;
  const type = response.headers?.get('content-type') || '';
  if (!/^application\/json(?:\s*;|$)/i.test(type)) return null;
  const length = response.headers?.get('content-length');
  if (length !== null && (!/^\d+$/.test(length) ||
      Number(length) > MAX_JWKS_BYTES)) return null;
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array)) return null;
      size += value.byteLength;
      if (size > MAX_JWKS_BYTES) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (size === 0) return null;
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    if (!value || !Array.isArray(value.keys) ||
        value.keys.length < 1 || value.keys.length > 64) return null;
    const seen = new Set();
    for (const key of value.keys) {
      if (!key || typeof key !== 'object' || Array.isArray(key) ||
          typeof key.kid !== 'string' || !key.kid ||
          key.kid.length > 128 || seen.has(key.kid) ||
          key.kty !== 'RSA' ||
          typeof key.n !== 'string' || typeof key.e !== 'string') return null;
      seen.add(key.kid);
    }
    return { keys: value.keys };
  } catch (_) {
    return null;
  }
}

/**
 * Construct once per isolated Web runtime instance (not once per request).
 * All dependencies are trusted server-side values. fetchImpl/nowSeconds are
 * injectable ONLY for local tests and must never derive from request JSON.
 *
 * Cache TTL defaults to 60 seconds, max 300; expiry fails closed if keys
 * cannot be refreshed. Unknown key IDs cause a bounded rotation refresh
 * (at most once each 15 seconds per instance). No token/keys are logged.
 */
export function createCloudflareAccessPrincipalResolver({
  expectedIssuer,
  expectedAudience,
  fetchImpl = fetch,
  nowSeconds = () => Math.floor(Date.now() / 1000),
  cacheTtlSeconds = 60,
  timeoutMs = 5000,
} = {}) {
  const validConfig = typeof expectedIssuer === 'string' &&
    ISSUER.test(expectedIssuer) &&
    typeof expectedAudience === 'string' &&
    expectedAudience.trim().length > 0 &&
    expectedAudience.length <= 512 &&
    typeof fetchImpl === 'function' &&
    typeof nowSeconds === 'function' &&
    Number.isSafeInteger(cacheTtlSeconds) &&
    cacheTtlSeconds >= 1 && cacheTtlSeconds <= 300 &&
    Number.isSafeInteger(timeoutMs) &&
    timeoutMs >= 500 && timeoutMs <= 10000;
  const certsUrl = validConfig
    ? expectedIssuer + '/cdn-cgi/access/certs' : null;
  let cached = null;
  let inFlight = null;
  let lastForcedRefresh = Number.NEGATIVE_INFINITY;

  async function fetchKeys() {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetchImpl(certsUrl, {
        method: 'GET',
        redirect: 'error',
        credentials: 'omit',
        cache: 'no-store',
        headers: { Accept: 'application/json' },
        signal: controller.signal,
      });
      // Reject a fake/mock response claiming a different origin or URL,
      // even if the fetch implementation did not honor redirect:'error'.
      if (typeof response?.url === 'string' && response.url &&
          response.url !== certsUrl) return null;
      return await readBoundedJson(response);
    } catch (_) {
      return null;
    } finally {
      clearTimeout(timer);
    }
  }

  async function keys(force, now) {
    if (!force && cached && now < cached.expiresAt) return cached.value;
    if (force && now - lastForcedRefresh < 15) return null;
    if (force) lastForcedRefresh = now;
    if (!inFlight) {
      inFlight = (async () => {
        const fetched = await fetchKeys();
        if (!fetched) return null;
        const afterFetch = nowSeconds();
        if (!Number.isSafeInteger(afterFetch) || afterFetch <= 0) return null;
        cached = { value: fetched, expiresAt: afterFetch + cacheTtlSeconds };
        return fetched;
      })();
      // Reset even if fetch failed; never cache a failed lookup.
      inFlight = inFlight.finally(() => { inFlight = null; });
    }
    return await inFlight;
  }

  async function resolve(request) {
    if (!validConfig) return failure('invalid_access_configuration');
    const now = nowSeconds();
    if (!Number.isSafeInteger(now) || now <= 0) {
      return failure('invalid_access_configuration');
    }
    // Never accept CF_Authorization cookie, browser-supplied principal,
    // ownerSubject, or verifiedBy markers as proof of authentication.
    const assertion = request?.headers?.get?.('cf-access-jwt-assertion');
    if (typeof assertion !== 'string' || !assertion ||
        assertion.length > MAX_ASSERTION_BYTES ||
        !JWT_SHAPE.test(assertion)) return failure('access_assertion_required');
    let jwks = await keys(false, now);
    if (!jwks) return failure('access_keys_unavailable');
    let result = await verifyCloudflareAccessAssertion({
      assertion, expectedIssuer, expectedAudience, jwks, nowSeconds: now,
    });
    if (result.reason === 'untrusted_access_keys') {
      // Cloudflare rotates keys. Re-check only the pinned issuer and only
      // once per cooldown window; never follow a kid/URL from the JWT.
      jwks = await keys(true, now);
      if (!jwks) return failure('access_keys_unavailable');
      result = await verifyCloudflareAccessAssertion({
        assertion, expectedIssuer, expectedAudience, jwks, nowSeconds: now,
      });
    }
    if (!result.ok) return failure('invalid_access_assertion');
    return result; // INTERNAL principal; an HTTP handler must not serialize it.
  }
  return Object.freeze({ resolve });
}
