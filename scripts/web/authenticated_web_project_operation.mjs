// AIVEXUS Web authenticated operation gate.
// The Pages Function must construct this handler with trusted environment
// Access issuer/audience, expected browser origin, Web-owned D1 binding and
// one fixed operation. Never derive factory options from request JSON/headers.
// Authentication always verifies the Access JWT signature and claims before
// touching D1. Client JSON is only an operation-specific CAS precondition.

import { createCloudflareAccessPrincipalResolver } from './cloudflare_access_principal_resolver.mjs';
import { createWebD1ReservationStore } from './d1_approval_reservation_store.mjs';
import { approveTrustedWebProposal, revokeTrustedWebApproval, stageTrustedWebCounterProposal } from
  './d1_web_proposal_approval_writer.mjs';
import { reserveApprovedWebExecution } from './approved_execution_reservation.mjs';
import { readWebExecutionZip } from './web_execution_artifact_download.mjs';
import { handleWebCounterAdvance } from './advance_web_counter.mjs';
import { generateWebApplication, readWebApplicationGeneration, readWebApplicationQuota } from './generate_web_application.mjs';
import {
  advanceWebApplicationVerification, readWebApplicationVerification, readWebApplicationZip,
  readVerifiedWebApplicationSource,
} from './d1_web_application_verification.mjs';
import { previewWebApplication } from './web_application_preview.mjs';

const MAX_JSON_BYTES = 2048;
// Generation prompts may be up to 8000 graphemes including multibyte text.
// All non-generation operations keep their existing strict 2 KiB cap.
const MAX_GENERATION_JSON_BYTES = 49152;
const OPERATIONS = new Set([
  'stage_counter', 'approve', 'revoke', 'reserve', 'status', 'download', 'advance',
  'generate_app', 'generation_status', 'generation_quota',
  'verify_app', 'verification_status', 'download_app', 'read_app_source', 'preview_app',
]);
const PROJECT_ID = /^[a-z0-9][a-z0-9._:-]{0,127}$/i;
const JSON_TYPE = /^application\/json(?:\s*;\s*charset=utf-8)?$/i;

function respond(status, data) {
  return new Response(JSON.stringify({ version: 1, ...data }), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
    },
  });
}
function reject(status, reason) {
  return respond(status, { ok: false, error: reason });
}
function serverConfigValid({ operation, expectedOrigin, db }) {
  if (!OPERATIONS.has(operation) || typeof expectedOrigin !== 'string' ||
      !db || typeof db.prepare !== 'function') return false;
  try {
    const url = new URL(expectedOrigin);
    return url.protocol === 'https:' && url.origin === expectedOrigin &&
      url.pathname === '/' && !url.username && !url.password &&
      !url.search && !url.hash;
  } catch (_) {
    return false;
  }
}
async function readJson(request, maxBytes = MAX_JSON_BYTES) {
  if (!JSON_TYPE.test(request.headers.get('content-type') || '')) {
    return { ok: false, status: 415, reason: 'json_required' };
  }
  const length = request.headers.get('content-length');
  if (length !== null &&
      (!/^\d+$/.test(length) || Number(length) > maxBytes)) {
    return { ok: false, status: 413, reason: 'request_too_large' };
  }
  if (!request.body || typeof request.body.getReader !== 'function') {
    return { ok: false, status: 400, reason: 'invalid_request' };
  }
  let size = 0;
  const chunks = [];
  const reader = request.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array)) {
        return { ok: false, status: 400, reason: 'invalid_request' };
      }
      size += value.byteLength;
      if (size > maxBytes) {
        await reader.cancel().catch(() => {});
        return { ok: false, status: 413, reason: 'request_too_large' };
      }
      chunks.push(value);
    }
  } catch (_) {
    return { ok: false, status: 400, reason: 'invalid_request' };
  } finally {
    reader.releaseLock();
  }
  if (size === 0) return { ok: false, status: 400, reason: 'invalid_request' };
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, at);
    at += chunk.length;
  }
  try {
    const parsed = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return { ok: false, status: 400, reason: 'invalid_request' };
    }
    return { ok: true, value: parsed };
  } catch (_) {
    return { ok: false, status: 400, reason: 'invalid_request' };
  }
}
function operationFailure(result) {
  const reason = result?.reason;
  if (reason === 'invalid_request') return reject(400, 'invalid_request');
  if (reason === 'execution_not_found') return reject(404, 'execution_not_found');
  if (reason === 'generation_not_found') return reject(404, 'generation_not_found');
  if (reason === 'generation_conflict') return reject(409, 'generation_conflict');
  if (reason === 'generation_quota_exceeded') return reject(429, reason);
  if (reason === 'generation_unavailable') return reject(503, 'generation_unavailable');
  if (reason === 'verification_checks_missing') return reject(409, 'verification_checks_missing');
  if (reason === 'verification_payload_too_large') return reject(413, 'verification_payload_too_large');
  if (reason === 'verification_unavailable') return reject(503, 'verification_unavailable');
  if (reason === 'storage_unavailable' ||
      reason === 'storage_inconsistent') return reject(503, 'storage_unavailable');
  if (reason === 'approval_required' ||
      reason === 'stale_or_not_ready') return reject(409, 'approval_not_ready');
  return reject(503, 'operation_unavailable');
}

function zipResponse(bytes, filename) {
  return new Response(bytes, {
    headers: {
      'Content-Type': 'application/zip',
      'Content-Disposition': `attachment; filename="${filename}"`,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
    },
  });
}

/**
 * Creates a Web-owned gate for one server-selected operation.
 * fetchImpl/nowSeconds are test seams. Do NOT feed them from browser input.
 * No public endpoint is registered by calling this factory.
 */
export function createAuthenticatedWebProjectOperation({
  operation, expectedOrigin, accessIssuer, accessAudience, db, bucket, runner,
  infer, fetchImpl, nowSeconds,
} = {}) {
  const config = { operation, expectedOrigin, db };
  const readsStatus = operation === 'status';
  const downloads = operation === 'download';
  const readsGeneration = operation === 'generation_status';
  const readsQuota = operation === 'generation_quota';
  const readsVerification = operation === 'verification_status';
  const downloadsApp = operation === 'download_app';
  const previewsApp = operation === 'preview_app';
  const readsSource = operation === 'read_app_source' || previewsApp;
  const readOnly = readsStatus || downloads || readsGeneration || readsQuota || readsVerification || downloadsApp || readsSource;
  const resolver = createCloudflareAccessPrincipalResolver({
    expectedIssuer: accessIssuer, expectedAudience: accessAudience,
    ...(fetchImpl ? { fetchImpl } : {}),
    ...(nowSeconds ? { nowSeconds } : {}),
  });
  return async function handle(request) {
    if (!serverConfigValid(config) || (downloads && typeof bucket?.get !== 'function')) {
      return reject(503, 'operation_unavailable');
    }
    if (!request || request.method !== (readOnly ? 'GET' : 'POST') ||
        !request.headers || typeof request.headers.get !== 'function') {
      return reject(405, 'method_not_allowed');
    }
    // State-changing requests must be same-origin. Access cookie/login and
    // a signed JWT are not a replacement for CSRF origin checks.
    let url;
    try { url = new URL(request.url); } catch (_) {
      return reject(400, 'invalid_request');
    }
    const origin = request.headers.get('origin');
    if (url.origin !== expectedOrigin ||
        ((!readOnly || origin !== null) && origin !== expectedOrigin) ||
        request.headers.get('sec-fetch-site') === 'cross-site') {
      return reject(403, 'origin_forbidden');
    }

    let verified;
    try {
      verified = await resolver.resolve(request);
    } catch (_) {
      return reject(503, 'access_unavailable');
    }
    if (!verified?.ok || verified.principal?.verifiedBy !== 'cloudflare-access-jwt' ||
        typeof verified.principal?.subject !== 'string') {
      if (verified?.reason === 'access_keys_unavailable' ||
          verified?.reason === 'invalid_access_configuration') {
        return reject(503, 'access_unavailable');
      }
      return reject(401, 'access_denied');
    }

    if (downloads) {
      if (url.searchParams.size !== 1) return reject(400, 'invalid_request');
      try {
        const result = await readWebExecutionZip({
          db, bucket, ownerSubject: verified.principal.subject,
          executionId: url.searchParams.get('executionId'),
        });
        if (result.error === 'invalid_request') return reject(400, result.error);
        if (result.error === 'execution_not_found') return reject(404, result.error);
        if (result.error) return reject(503, result.error);
        return zipResponse(result.bytes, 'aivexus-counter.zip');
      } catch (_) {
        return reject(503, 'artifact_unavailable');
      }
    }

    if (readsStatus) {
      const [projectId] = url.searchParams.getAll('projectId');
      if (!PROJECT_ID.test(projectId ?? '') ||
          url.searchParams.size !== 1) {
        return reject(400, 'invalid_request');
      }
      try {
        const execution = await createWebD1ReservationStore(db).readLatestExecution({
          ownerSubject: verified.principal.subject, projectId,
        });
        if (!execution) return reject(404, 'execution_not_found');
        const { executionId, attemptId, revision, status } = execution;
        return respond(200, { ok: true, executionId, attemptId, revision, status });
      } catch (_) {
        return reject(503, 'storage_unavailable');
      }
    }

    if (readsQuota) {
      if (url.searchParams.size !== 0) return reject(400, 'invalid_request');
      try {
        const result = await readWebApplicationQuota({
          db, ownerSubject: verified.principal.subject,
        });
        if (!result.ok) return operationFailure(result);
        return respond(200, result);
      } catch (_) {
        return reject(503, 'storage_unavailable');
      }
    }

    if (readsGeneration || readsVerification || downloadsApp || readsSource) {
      if (url.searchParams.size !== 1) return reject(400, 'invalid_request');
      try {
        const read = downloadsApp ? readWebApplicationZip : readsSource ? readVerifiedWebApplicationSource :
          readsVerification ? readWebApplicationVerification : readWebApplicationGeneration;
        const result = await read({
          db, ownerSubject: verified.principal.subject,
          generationId: url.searchParams.get('generationId'),
        });
        if (!result.ok) return operationFailure(result);
        if (previewsApp) return previewWebApplication(result.source);
        return downloadsApp ? zipResponse(result.bytes, 'aivexus-application.zip') : respond(200, result);
      } catch (_) {
        return reject(503, 'storage_unavailable');
      }
    }

    const parsed = await readJson(request, operation === 'generate_app' ? MAX_GENERATION_JSON_BYTES : MAX_JSON_BYTES);
    if (!parsed.ok) return reject(parsed.status, parsed.reason);

    let result;
    try {
      const principal = verified.principal;
      if (operation === 'generate_app') {
        result = await generateWebApplication({ request: parsed.value, ownerSubject: principal.subject, db, infer });
      } else if (operation === 'verify_app') {
        result = await advanceWebApplicationVerification({ request: parsed.value, ownerSubject: principal.subject, db, runner });
      } else if (operation === 'advance') {
        result = await handleWebCounterAdvance({ request: parsed.value, principal, db, bucket, runner });
      } else if (operation === 'stage_counter') {
        result = await stageTrustedWebCounterProposal({
          request: parsed.value, principal, db,
        });
      } else if (operation === 'approve') {
        result = await approveTrustedWebProposal({
          request: parsed.value, principal, db,
        });
      } else if (operation === 'revoke') {
        result = await revokeTrustedWebApproval({
          request: parsed.value, principal, db,
        });
      } else {
        result = await reserveApprovedWebExecution({
          request: parsed.value, principal,
          store: createWebD1ReservationStore(db),
        });
      }
    } catch (_) {
      return reject(503, 'operation_unavailable');
    }
    if (!result?.ok) return operationFailure(result);
    // Writer/reservation return sanitized receipts only. Never serialize
    // access assertion, principal, DB row, spec contents or provider payload.
    const { ok, ...receipt } = result;
    return respond(200, { ok, ...receipt });
  };
}
