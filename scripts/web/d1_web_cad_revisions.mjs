import { runnerPayloadSha256 } from './web_application_runner_packet.mjs';
import { WEB_RUNNER_TICKET } from './web_runner_envelope.mjs';

export const WEB_CAD_PROJECT_ID = /^(?:web-project:[0-9]{1,20}|[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/;

const invalid = () => ({ ok: false, reason: 'invalid_cad_result' });

/** Called by trusted runner ingestion after authenticating the result and owner. */
export async function saveWebCadRevision({
  db, ownerSubject, projectId, revisionId, baseRevisionId = null, manifest, scad, stl,
}) {
  if (!ownerSubject || !WEB_CAD_PROJECT_ID.test(projectId) || !WEB_RUNNER_TICKET.test(revisionId) ||
      (baseRevisionId !== null && !WEB_RUNNER_TICKET.test(baseRevisionId)) ||
      manifest?.version !== 1 || manifest.kind !== 'cad' || manifest.shape !== 'open_box' ||
      manifest.unit !== 'mm' || !Array.isArray(manifest.files) || manifest.files.length !== 2) {
    return invalid();
  }
  for (const [name, data, type] of [
    ['box.scad', scad, 'text/plain'],
    ['box.stl', stl, 'model/stl'],
  ]) {
    const entry = manifest.files.find(file => file?.name === name);
    if (!(data instanceof Uint8Array) || data.length < 1 || data.length > 65536 ||
        entry?.mediaType !== type || entry?.bytes !== data.length ||
        entry.sha256 !== await runnerPayloadSha256(data)) {
      return invalid();
    }
  }
  const encoded = JSON.stringify(manifest);
  if (encoded.length > 4096) return invalid();

  const row = await db.prepare(`
    INSERT INTO web_cad_revisions (
      owner_subject, project_id, revision_id, base_revision_id, revision_number,
      manifest_json, scad_bytes, stl_bytes
    )
    SELECT ?1, ?2, ?3, ?4, CASE WHEN ?4 IS NULL THEN 1 ELSE (SELECT COALESCE(MAX(revision_number), 0) + 1
      FROM web_cad_revisions WHERE owner_subject = ?1 AND project_id = ?2) END, ?5, ?6, ?7
    FROM (SELECT 1) AS candidate
    LEFT JOIN web_cad_revisions AS base
      ON base.owner_subject = ?1 AND base.project_id = ?2 AND base.revision_id = ?4
    WHERE (?4 IS NULL OR base.revision_id IS NOT NULL)
    ON CONFLICT DO NOTHING
    RETURNING revision_number AS revisionNumber
  `).bind(ownerSubject, projectId, revisionId, baseRevisionId, encoded,
    Uint8Array.from(scad).buffer, Uint8Array.from(stl).buffer).first();
  return row ? { ok: true, revisionNumber: row.revisionNumber } :
    { ok: false, reason: 'cad_revision_conflict' };
}

export async function readWebCadRevision({ db, ownerSubject, projectId, revisionId }) {
  const row = await db.prepare(`
    SELECT revision_id AS revisionId, revision_number AS revisionNumber,
      base_revision_id AS baseRevisionId, manifest_json AS manifest,
      scad_bytes AS scad, stl_bytes AS stl
    FROM web_cad_revisions
    WHERE owner_subject = ?1 AND project_id = ?2 AND revision_id = ?3
  `).bind(ownerSubject, projectId, revisionId).first();
  if (!row) return { ok: false, reason: 'cad_revision_not_found' };
  return { ok: true, ...row, manifest: JSON.parse(row.manifest) };
}

export async function listWebCadRevisions({ db, ownerSubject, projectId }) {
  const query = await db.prepare(`
    SELECT revision_id AS revisionId, revision_number AS revisionNumber,
      revision_id IS (SELECT revision_id FROM web_cad_project_selection WHERE owner_subject = ?1 AND project_id = ?2) AS selected,
      base_revision_id AS baseRevisionId, json_extract(manifest_json, '$.parameters') AS parametersJson,
      json_extract(manifest_json, '$.photoEstimates') AS photoEstimatesJson
    FROM web_cad_revisions
    WHERE owner_subject = ?1 AND project_id = ?2
    ORDER BY selected DESC, revision_number DESC LIMIT 50
  `).bind(ownerSubject, projectId).all();
  if (query.success === false || !Array.isArray(query.results)) throw new Error('CAD history unavailable');
  return query.results.map(({ parametersJson, photoEstimatesJson, selected, ...revision }) => ({
    ...revision, selected: Boolean(selected), parameters: parametersJson ? JSON.parse(parametersJson) : null,
    photoEstimates: photoEstimatesJson ? JSON.parse(photoEstimatesJson) : [],
  }));
}

export async function selectWebCadRevision({ db, ownerSubject, projectId, revisionId }) {
  if (!WEB_CAD_PROJECT_ID.test(projectId) || !WEB_RUNNER_TICKET.test(revisionId)) return invalid();
  const row = await db.prepare(`
    INSERT INTO web_cad_project_selection(owner_subject, project_id, revision_id)
    SELECT owner_subject, project_id, revision_id FROM web_cad_revisions
    WHERE owner_subject = ?1 AND project_id = ?2 AND revision_id = ?3
    ON CONFLICT(owner_subject, project_id) DO UPDATE SET revision_id = excluded.revision_id
    RETURNING revision_id AS activeRevisionId
  `).bind(ownerSubject, projectId, revisionId).first();
  return row ? { ok: true, activeRevisionId: row.activeRevisionId } :
    { ok: false, reason: 'cad_revision_conflict' };
}
