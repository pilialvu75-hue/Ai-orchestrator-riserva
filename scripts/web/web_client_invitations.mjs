// AIVEXUS Web-only client onboarding, exclusively behind Cloudflare Access.
// An owner invite is not an Access policy: both verified identity AND an
// accepted unexpired invitation are required to use client workspaces.
// This code never sends email, generates a paid provider request, or grants
// admin privileges.
import { createCloudflareAccessPrincipalResolver } from './cloudflare_access_principal_resolver.mjs';
import { existingWebOwnerSubject } from './web_owner_role.mjs';

const ID = /^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
const EMAIL = /^[^\s@<>]{1,64}@[a-z0-9.-]+\.[a-z]{2,}$/i;
const MAX_BODY = 2048;
const OPERATIONS = new Set(['create', 'list', 'claim', 'revoke', 'status']);

function normalizedEmail(value) {
  if (typeof value !== 'string' || value.length > 254) return null;
  const email = value.trim().toLowerCase();
  return EMAIL.test(email) && !email.includes('..') ? email : null;
}
function result(status, data) {
  return new Response(JSON.stringify({ version: 1, ...data }), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
    },
  });
}
const deny = (status, error) => result(status, { ok: false, error });
function changes(value) {
  return Number(value?.meta?.changes ?? value?.changes ?? 0);
}

export async function activeWebCustomerGrant({ db, principal }) {
  const email = normalizedEmail(principal?.email);
  if (!email || principal?.verifiedBy !== 'cloudflare-access-jwt' ||
      typeof principal.subject !== 'string' || !principal.subject) return false;
  const row = await db.prepare(`SELECT 1 AS permitted
    FROM web_client_invitations
    WHERE customer_subject = ?1 AND recipient_email = ?2
      AND status = 'accepted' AND expires_at > unixepoch()
    LIMIT 1`).bind(principal.subject, email).first();
  return row?.permitted === 1;
}

export async function createWebClientInvitation({ db, ownerSubject, email, expiresDays }) {
  const recipient = normalizedEmail(email);
  if (!ownerSubject || !recipient || !Number.isInteger(expiresDays) ||
      expiresDays < 1 || expiresDays > 30) {
    return { ok: false, error: 'invalid_request', httpStatus: 400 };
  }
  const id = crypto.randomUUID();
  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + expiresDays * 86400;
  const saved = await db.prepare(`INSERT INTO web_client_invitations
    (invitation_id, owner_subject, recipient_email, status, expires_at)
    SELECT ?1, ?2, ?3, 'pending', unixepoch() + ?4
    WHERE (SELECT COUNT(*) FROM web_client_invitations
      WHERE owner_subject = ?2 AND status != 'revoked'
        AND expires_at > unixepoch()) < 100
    AND NOT EXISTS (SELECT 1 FROM web_client_invitations
      WHERE owner_subject = ?2 AND recipient_email = ?3
        AND status != 'revoked' AND expires_at > unixepoch())`)
    .bind(id, ownerSubject, recipient, expiresDays * 86400).run();
  if (changes(saved) !== 1) return {
    ok: false, error: 'invitation_conflict_or_limit', httpStatus: 409,
  };
  return { ok: true, invitationId: id, recipientEmail: recipient,
    status: 'pending', expiresAt: new Date(expiresAt * 1000).toISOString() };
}

export async function listWebClientInvitations({ db, ownerSubject }) {
  const rows = await db.prepare(`SELECT invitation_id AS invitationId,
    recipient_email AS recipientEmail,
    CASE WHEN status != 'revoked' AND expires_at <= unixepoch()
      THEN 'expired' ELSE status END AS status,
    created_at AS createdAt, expires_at AS expiresAt,
    CASE WHEN customer_subject IS NULL THEN 0 ELSE 1 END AS linked
    FROM web_client_invitations WHERE owner_subject = ?1
    ORDER BY created_at DESC, invitation_id DESC LIMIT 100`)
    .bind(ownerSubject).all();
  const data = Array.isArray(rows) ? rows : rows?.results;
  if (!Array.isArray(data)) throw new Error('D1 query failed');
  return { ok: true, invitations: data.map(x => ({
    invitationId: x.invitationId, recipientEmail: x.recipientEmail,
    status: x.status, linked: x.linked === 1,
    createdAt: new Date(x.createdAt * 1000).toISOString(),
    expiresAt: new Date(x.expiresAt * 1000).toISOString(),
  })) };
}

export async function revokeWebClientInvitation({ db, ownerSubject, invitationId }) {
  if (!ID.test(invitationId ?? '')) {
    return { ok: false, error: 'invalid_request', httpStatus: 400 };
  }
  const saved = await db.prepare(`UPDATE web_client_invitations
    SET status = 'revoked'
    WHERE owner_subject = ?1 AND invitation_id = ?2
      AND status != 'revoked'`).bind(ownerSubject, invitationId).run();
  return changes(saved) === 1 ? { ok: true, status: 'revoked' } :
    { ok: false, error: 'invitation_not_found', httpStatus: 404 };
}

export async function claimWebClientInvitation({ db, principal, invitationId }) {
  const email = normalizedEmail(principal?.email);
  if (!ID.test(invitationId ?? '') || !email ||
      principal?.verifiedBy !== 'cloudflare-access-jwt' ||
      typeof principal?.subject !== 'string' || !principal.subject) {
    return { ok: false, error: 'invalid_request', httpStatus: 400 };
  }
  // The signed Access email AND opaque ID must match. One successful claim
  // atomically binds this invitation to the signed Access subject.
  const row = await db.prepare(`UPDATE web_client_invitations
    SET status = 'accepted', customer_subject = ?1, accepted_at = unixepoch()
    WHERE invitation_id = ?2 AND recipient_email = ?3
      AND owner_subject != ?1 AND customer_subject IS NULL
      AND status = 'pending' AND expires_at > unixepoch()
    RETURNING invitation_id AS invitationId, expires_at AS expiresAt`)
    .bind(principal.subject, invitationId, email).first();
  if (!row) return { ok: false, error: 'invitation_not_found', httpStatus: 404 };
  return { ok: true, status: 'accepted',
    expiresAt: new Date(row.expiresAt * 1000).toISOString() };
}

async function boundedBody(request) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(
    request.headers.get('content-type') || '')) return null;
  if (Number(request.headers.get('content-length') || 0) > MAX_BODY) return null;
  const reader = request.body?.getReader?.();
  if (!reader) return null;
  const chunks = [];
  let n = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      n += value.byteLength;
      if (n > MAX_BODY) return null;
      chunks.push(value);
    }
    if (n === 0) return null;
    const bytes = new Uint8Array(n);
    let i = 0;
    for (const part of chunks) { bytes.set(part, i); i += part.byteLength; }
    const obj = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    return obj && typeof obj === 'object' && !Array.isArray(obj) ? obj : null;
  } catch (_) { return null; }
  finally { reader.releaseLock(); }
}

export function createWebCustomerAccessHandler({
  operation, expectedOrigin, accessIssuer, accessAudience,
  configuredOwnerSubject, configuredOwnerEmail, clientAccessEnabled = false,
  enrollmentPaused = true, db, fetchImpl,
} = {}) {
  const resolver = createCloudflareAccessPrincipalResolver({
    expectedIssuer: accessIssuer, expectedAudience: accessAudience,
    ...(fetchImpl ? { fetchImpl } : {}),
  });
  return async request => {
    if (!OPERATIONS.has(operation) || !db?.prepare ||
        typeof expectedOrigin !== 'string') return deny(503, 'access_unavailable');
    const readonly = operation === 'list' || operation === 'status';
    if (request?.method !== (readonly ? 'GET' : 'POST')) {
      return deny(405, 'method_not_allowed');
    }
    let url;
    try { url = new URL(request.url); } catch (_) {
      return deny(400, 'invalid_request');
    }
    if (url.origin !== expectedOrigin || url.searchParams.size !== 0 ||
        (request.headers.get('origin') !== null &&
          request.headers.get('origin') !== expectedOrigin) ||
        (!readonly && request.headers.get('origin') !== expectedOrigin) ||
        request.headers.get('sec-fetch-site') === 'cross-site') {
      return deny(403, 'origin_forbidden');
    }
    const auth = await resolver.resolve(request).catch(() => null);
    if (!auth?.ok || auth.principal?.verifiedBy !== 'cloudflare-access-jwt') {
      return deny(401, 'access_denied');
    }
    const principal = auth.principal;
    const owner = existingWebOwnerSubject({
      principal, configuredSubject: configuredOwnerSubject,
      configuredEmail: configuredOwnerEmail,
    });
    // Keep role status read-only while enrollment is paused.
    if (enrollmentPaused && operation !== 'status') {
      return deny(403, 'client_service_paused');
    }
    if (enrollmentPaused) {
      return result(200, {
        ok: true, role: owner ? 'owner' : 'uninvited',
        clientEnabled: false, canUseStudio: !!owner,
        customerService: 'paused',
      });
    }
    if (['create', 'list', 'revoke'].includes(operation) && !owner) {
      return deny(403, 'owner_required');
    }
    const body = readonly ? null : await boundedBody(request);
    if (!readonly && !body) return deny(400, 'invalid_request');
    try {
      let output;
      if (operation === 'create') {
        if (Object.keys(body).sort().join(',') !== 'email,expiresDays') {
          return deny(400, 'invalid_request');
        }
        output = await createWebClientInvitation({
          db, ownerSubject: owner, email: body.email, expiresDays: body.expiresDays,
        });
      } else if (operation === 'list') {
        output = await listWebClientInvitations({ db, ownerSubject: owner });
      } else if (operation === 'revoke') {
        if (Object.keys(body).join(',') !== 'invitationId') {
          return deny(400, 'invalid_request');
        }
        output = await revokeWebClientInvitation({
          db, ownerSubject: owner, invitationId: body.invitationId,
        });
      } else if (operation === 'claim') {
        if (Object.keys(body).join(',') !== 'invitationId') {
          return deny(400, 'invalid_request');
        }
        output = await claimWebClientInvitation({ db, principal,
          invitationId: body.invitationId });
      } else {
        const active = owner ? false : await activeWebCustomerGrant({ db, principal });
        output = { ok: true, role: owner ? 'owner' : active ? 'client' : 'uninvited',
          clientEnabled: clientAccessEnabled === true,
          canUseStudio: !!owner || (clientAccessEnabled === true && active) };
      }
      const { httpStatus = 200, ...safe } = output;
      return result(httpStatus, safe);
    } catch (_) {
      return deny(503, 'storage_unavailable');
    }
  };
}
