import { readVerifiedWebApplicationSource } from './d1_web_application_verification.mjs';
import { encodeRunnerBase64, runnerPayloadSha256 } from './web_application_runner_packet.mjs';
import { WEB_RUNNER_TICKET as GENERATION_ID } from './web_runner_envelope.mjs';

const TOKEN = /^[A-Za-z0-9+/]{43}=$/;
const MAX_AGE_SECONDS = 24 * 60 * 60;
const encoder = new TextEncoder();
const fail = reason => ({ ok: false, reason });
const validId = id => typeof id === 'string' && GENERATION_ID.test(id);

export async function resolveWebApplicationAccess({ db, viewerSubject, generationId }) {
  if (!validId(generationId)) return fail('invalid_request');
  const own = await db.prepare(`SELECT owner_subject AS projectOwner, COALESCE(project_id, generation_id) AS projectId
    FROM web_app_generations WHERE owner_subject = ?1 AND generation_id = ?2`).bind(viewerSubject, generationId).first();
  if (own) return { ok: true, ...own };
  const memberships = await db.prepare(`SELECT g.owner_subject AS projectOwner, COALESCE(g.project_id, g.generation_id) AS projectId
    FROM web_app_generations AS g
    WHERE g.generation_id = ?2 AND EXISTS (
      SELECT 1 FROM web_app_invites AS i WHERE i.member_subject = ?1 AND i.project_owner = g.owner_subject
        AND i.project_id = COALESCE(g.project_id, g.generation_id)
    ) LIMIT 2`).bind(viewerSubject, generationId).all();
  if (!memberships?.success || !Array.isArray(memberships.results)) return fail('storage_unavailable');
  if (memberships.results.length !== 1) return fail('generation_not_found');
  return { ok: true, ...memberships.results[0] };
}

export async function readMemberWebApplicationSource({ db, ownerSubject: viewerSubject, generationId }) {
  const access = await resolveWebApplicationAccess({ db, viewerSubject, generationId });
  if (!access.ok) return access;
  return readVerifiedWebApplicationSource({ db, ownerSubject: access.projectOwner, generationId });
}

export async function createWebApplicationInvite({ db, ownerSubject, request }) {
  const { generationId } = request;
  if (Object.keys(request).length !== 1 || !validId(generationId)) return fail('invalid_request');
  const token = encodeRunnerBase64(crypto.getRandomValues(new Uint8Array(32)));
  const digest = await runnerPayloadSha256(encoder.encode(token));
  const row = await db.prepare(`INSERT INTO web_app_invites (token_sha256, project_owner, project_id, generation_id, expires_at)
    SELECT ?3, g.owner_subject, COALESCE(g.project_id, g.generation_id), g.generation_id, unixepoch() + ?4
    FROM web_app_generations AS g JOIN web_app_verifications AS v USING (owner_subject, generation_id)
    WHERE g.owner_subject = ?1 AND g.generation_id = ?2 AND v.status = 'verified'
    RETURNING expires_at AS expiresAt`).bind(ownerSubject, generationId, digest, MAX_AGE_SECONDS).first();
  return row ? { ok: true, token, expiresAt: row.expiresAt } : fail('generation_not_found');
}

export async function joinWebApplication({ db, ownerSubject, request }) {
  const { token } = request;
  if (Object.keys(request).length !== 1 || typeof token !== 'string' || !TOKEN.test(token)) return fail('invalid_request');
  const digest = await runnerPayloadSha256(encoder.encode(token));
  const joined = await db.prepare(`UPDATE web_app_invites SET member_subject = ?2
    WHERE token_sha256 = ?1 AND project_owner != ?2 AND member_subject IS NULL AND expires_at > unixepoch()
    RETURNING generation_id AS generationId`).bind(digest, ownerSubject).first();
  if (joined) return { ok: true, generationId: joined.generationId };
  const previous = await db.prepare(`SELECT generation_id AS generationId FROM web_app_invites
    WHERE token_sha256 = ?1 AND member_subject = ?2`).bind(digest, ownerSubject).first();
  return previous ? { ok: true, generationId: previous.generationId } : fail('invite_not_found');
}
