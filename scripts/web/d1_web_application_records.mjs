import { readVerifiedWebApplicationSource } from './d1_web_application_verification.mjs';
import { resolveWebApplicationAccess } from './d1_web_application_members.mjs';
import { normalizeWebApplicationRecord } from './web_application_runtime_schema.mjs';
import { WEB_RUNNER_TICKET as RECORD_ID } from './web_runner_envelope.mjs';

const RECORD_LIMIT = 50;
const MAX_DATA_BYTES = 16384;
const BASE_KEYS = ['generationId', 'action', 'collection'];
const ACTION_KEYS = {
  list: [], create: ['recordId', 'data'], update: ['recordId', 'version', 'data'], delete: ['recordId', 'version'],
};
const encoder = new TextEncoder();
const fail = reason => ({ ok: false, reason });
const validId = value => typeof value === 'string' && RECORD_ID.test(value);

function validateRequest(request) {
  const { generationId, action, collection, recordId, version, after } = request;
  if (!validId(generationId) || typeof action !== 'string' || !Object.hasOwn(ACTION_KEYS, action) ||
      typeof collection !== 'string' || collection.length > 32) return false;
  const required = [...BASE_KEYS, ...ACTION_KEYS[action]];
  if (required.some(key => !Object.hasOwn(request, key)) ||
      Object.keys(request).some(key => !required.includes(key) && !(action === 'list' && key === 'after'))) return false;
  if (action === 'list') return after === undefined || validId(after);
  if (!validId(recordId)) return false;
  return action === 'create' || (Number.isInteger(version) && version >= 1 && version < 2147483647);
}

function toRecord(row) {
  return { recordId: row.recordId, version: row.version, data: JSON.parse(row.dataJson) };
}

export async function operateWebApplicationRecords({ db, ownerSubject, request }) {
  if (!validateRequest(request)) return fail('invalid_request');
  const { generationId, action, collection, recordId, version, data, after } = request;
  const access = await resolveWebApplicationAccess({ db, viewerSubject: ownerSubject, generationId });
  if (!access.ok) return access;
  const verified = await readVerifiedWebApplicationSource({ db, ownerSubject: access.projectOwner, generationId });
  if (!verified.ok) return verified;
  const schema = verified.source.runtime?.collections.find(entry => entry.name === collection);
  if (!schema) return fail('collection_not_found');
  const scope = [access.projectOwner, access.projectId, ownerSubject, collection];

  if (action === 'list') {
    const page = await db.prepare(`SELECT record_id AS recordId, record_version AS version, data_json AS dataJson
      FROM web_app_records WHERE project_owner = ?1 AND project_id = ?2 AND user_subject = ?3 AND collection_name = ?4 AND record_id > ?5
      ORDER BY record_id LIMIT ?6`).bind(...scope, after ?? '', RECORD_LIMIT + 1).all();
    if (!page?.success || !Array.isArray(page.results)) return fail('storage_unavailable');
    const records = page.results.slice(0, RECORD_LIMIT).map(toRecord);
    return { ok: true, records, nextRecordId: page.results.length > RECORD_LIMIT ? records.at(-1).recordId : null };
  }
  if (action === 'delete') {
    const deleted = await db.prepare(`DELETE FROM web_app_records WHERE project_owner = ?1 AND project_id = ?2
      AND user_subject = ?3 AND collection_name = ?4 AND record_id = ?5 AND record_version = ?6 RETURNING record_id AS recordId`)
      .bind(...scope, recordId, version).first();
    return deleted ? { ok: true, recordId, deleted: true } : fail('record_conflict');
  }

  const normalized = normalizeWebApplicationRecord(schema, data);
  if (!normalized) return fail('invalid_record');
  const serialized = JSON.stringify(normalized);
  if (encoder.encode(serialized).byteLength > MAX_DATA_BYTES) return fail('invalid_record');
  const row = action === 'create'
    ? await db.prepare(`INSERT INTO web_app_records (project_owner, project_id, user_subject, collection_name, record_id, record_version, data_json)
        VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6) ON CONFLICT(project_owner, project_id, user_subject, collection_name, record_id) DO NOTHING
        RETURNING record_id AS recordId, record_version AS version, data_json AS dataJson`)
      .bind(...scope, recordId, serialized).first()
    : await db.prepare(`UPDATE web_app_records SET data_json = ?7, record_version = record_version + 1, updated_at = unixepoch()
        WHERE project_owner = ?1 AND project_id = ?2 AND user_subject = ?3 AND collection_name = ?4 AND record_id = ?5 AND record_version = ?6
        RETURNING record_id AS recordId, record_version AS version, data_json AS dataJson`)
      .bind(...scope, recordId, version, serialized).first();
  return row ? { ok: true, record: toRecord(row) } : fail('record_conflict');
}
