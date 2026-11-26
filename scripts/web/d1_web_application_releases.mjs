import { resolveWebApplicationAccess } from './d1_web_application_members.mjs';
import { readVerifiedWebApplicationSource } from './d1_web_application_verification.mjs';
import { WEB_RUNNER_TICKET as UUID } from './web_runner_envelope.mjs';

const fail = reason => ({ ok: false, reason });
const validId = value => typeof value === 'string' && UUID.test(value);
const PUBLIC_FIELDS = 'release_id AS releaseId, revision, generation_id AS generationId, action, created_at AS createdAt';
const LATEST = `SELECT ${PUBLIC_FIELDS}, project_owner AS projectOwner, project_id AS projectId
  FROM web_app_release_events WHERE release_id = ?1 ORDER BY revision DESC LIMIT 1`;

export async function changeWebApplicationRelease({ db, ownerSubject, request, releasesEnabled }) {
  const { action, releaseId, generationId, expectedRevision } = request;
  if (Object.keys(request).length !== 4 || !['publish', 'rollback'].includes(action) ||
      !validId(releaseId) || !validId(generationId) || !Number.isSafeInteger(expectedRevision) ||
      expectedRevision < 0 || expectedRevision >= 2147483647 || (action === 'rollback' && expectedRevision === 0)) {
    return fail('invalid_request');
  }
  const target = await readVerifiedWebApplicationSource({ db, ownerSubject, generationId });
  if (!target.ok) return target;
  if (!releasesEnabled) return fail('release_unavailable');

  const revision = expectedRevision + 1;
  const row = await db.prepare(`INSERT INTO web_app_release_events
    (release_id, revision, project_owner, project_id, generation_id, action)
    SELECT ?1, ?2, g.owner_subject, COALESCE(g.project_id, g.generation_id), g.generation_id, ?5
    FROM web_app_generations AS g JOIN web_app_verifications AS v USING (owner_subject, generation_id)
    WHERE g.owner_subject = ?3 AND g.generation_id = ?4 AND v.status = 'verified'
      AND ((?6 = 0 AND ?5 = 'publish' AND NOT EXISTS (
        SELECT 1 FROM web_app_release_events AS e WHERE e.release_id = ?1
          OR (e.project_owner = g.owner_subject AND e.project_id = COALESCE(g.project_id, g.generation_id))
      )) OR (?6 > 0 AND EXISTS (
        SELECT 1 FROM web_app_release_events AS e WHERE e.release_id = ?1 AND e.revision = ?6
          AND e.project_owner = g.owner_subject AND e.project_id = COALESCE(g.project_id, g.generation_id)
          AND NOT EXISTS (SELECT 1 FROM web_app_release_events AS n WHERE n.release_id = ?1 AND n.revision > ?6)
        ) AND (?5 = 'publish' OR EXISTS (
          SELECT 1 FROM web_app_release_events AS p WHERE p.release_id = ?1 AND p.generation_id = g.generation_id
            AND p.revision < ?6
        )))
      ) ON CONFLICT DO NOTHING RETURNING ${PUBLIC_FIELDS}`)
    .bind(releaseId, revision, ownerSubject, generationId, action, expectedRevision).first();
  if (row) return { ok: true, ...row };
  const repeated = await db.prepare(`SELECT ${PUBLIC_FIELDS} FROM web_app_release_events
    WHERE release_id = ?1 AND revision = ?2 AND project_owner = ?3 AND generation_id = ?4 AND action = ?5`)
    .bind(releaseId, revision, ownerSubject, generationId, action).first();
  return repeated ? { ok: true, ...repeated } : fail('release_conflict');
}

export async function readWebApplicationReleaseHistory({ db, ownerSubject, generationId }) {
  if (!validId(generationId)) return fail('invalid_request');
  const project = await db.prepare(`SELECT COALESCE(project_id, generation_id) AS projectId
    FROM web_app_generations WHERE owner_subject = ?1 AND generation_id = ?2`).bind(ownerSubject, generationId).first();
  if (!project) return fail('generation_not_found');
  const results = await db.prepare(`SELECT ${PUBLIC_FIELDS} FROM web_app_release_events
    WHERE project_owner = ?1 AND project_id = ?2 ORDER BY revision DESC LIMIT 100`)
    .bind(ownerSubject, project.projectId).all();
  if (!results?.success || !Array.isArray(results.results)) return fail('storage_unavailable');
  return { ok: true, active: results.results[0] ?? null, history: results.results };
}

export async function resolveWebApplicationRelease({ db, ownerSubject: viewerSubject, releaseId }) {
  if (!validId(releaseId)) return fail('invalid_request');
  const row = await db.prepare(LATEST).bind(releaseId).first();
  if (!row) return fail('generation_not_found');
  const access = await resolveWebApplicationAccess({ db, viewerSubject, generationId: row.generationId });
  if (!access.ok || access.projectOwner !== row.projectOwner || access.projectId !== row.projectId) {
    return fail('generation_not_found');
  }
  const verified = await readVerifiedWebApplicationSource({ db, ownerSubject: row.projectOwner, generationId: row.generationId });
  return verified.ok ? { ok: true, generationId: row.generationId } : verified;
}
