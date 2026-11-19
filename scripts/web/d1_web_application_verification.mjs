import { parseGeneratedWebApplication } from './generate_web_application.mjs';
import { createGitHubWebApplicationRunnerClient } from './github_counter_runner_client.mjs';
import { validateWebApplicationChecks } from './web_application_checks.mjs';
import {
  decodeRunnerBase64, decodeWebAppResult, encodeWebAppJob, importWebAppAuthorizationKey,
  importWebAppPrivateKey, importWebAppPublicKey, runnerPayloadSha256,
} from './web_application_runner_packet.mjs';
import { WEB_RUNNER_TICKET as GENERATION_ID } from './web_runner_envelope.mjs';

const SHA256 = /^[0-9a-f]{64}$/;
const HEAD = /^[0-9a-f]{40}$/;
const DIAGNOSIS = /^[a-z_]{1,64}$/;
const ZIP_LIMIT = 73728;
const encoder = new TextEncoder();
const READ = `SELECT ticket, job_sha256 AS jobSha256, head_sha AS headSha,
  source_sha256 AS sourceSha256, run_id AS runId, status, receipt_json AS receiptJson,
  unixepoch() - updated_at AS age
  FROM web_app_verifications WHERE owner_subject = ?1 AND generation_id = ?2`;
const GENERATION = `SELECT result_json AS resultJson FROM web_app_generations
  WHERE owner_subject = ?1 AND generation_id = ?2 AND status = 'generated'`;
const CLAIM = `INSERT INTO web_app_verifications
  (owner_subject, generation_id, ticket, head_sha, job_sha256, source_sha256, status)
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'dispatching')
  ON CONFLICT(owner_subject, generation_id) DO NOTHING RETURNING ticket`;
const DISPATCHED = `UPDATE web_app_verifications SET status = ?4, run_id = ?5, updated_at = unixepoch()
  WHERE owner_subject = ?1 AND generation_id = ?2 AND ticket = ?3 AND status = 'dispatching' RETURNING ticket`;
const IMPORT = `UPDATE web_app_verifications SET status = 'importing', import_id = ?4, updated_at = unixepoch()
  WHERE owner_subject = ?1 AND generation_id = ?2 AND run_id = ?3
    AND (status = 'submitted' OR (status = 'importing' AND unixepoch() - updated_at >= 60)) RETURNING ticket`;
const FINISH = `UPDATE web_app_verifications SET status = ?4, receipt_json = ?5, source_json = ?6,
  zip_sha256 = ?7, zip_bytes = ?8, import_id = NULL, updated_at = unixepoch()
  WHERE owner_subject = ?1 AND generation_id = ?2 AND status = 'importing' AND import_id = ?3 RETURNING ticket`;

const failure = reason => ({ ok: false, reason });
const validId = id => typeof id === 'string' && GENERATION_ID.test(id);
const digest = value => typeof value === 'string' && SHA256.test(value);

function receipt(generationId, row) {
  if (!row) return { ok: true, generationId, status: 'ready' };
  const status = row.status === 'dispatching' && row.age >= 60 ? 'review_required' : row.status;
  return { ok: true, generationId, status, ...(row.receiptJson ? JSON.parse(row.receiptJson) : {}) };
}

export async function readWebApplicationVerification({ db, ownerSubject, generationId }) {
  if (!validId(generationId)) return failure('invalid_request');
  const row = await db.prepare(READ).bind(ownerSubject, generationId).first();
  if (row) return receipt(generationId, row);
  const generation = await db.prepare(GENERATION).bind(ownerSubject, generationId).first();
  if (!generation) return failure('generation_not_found');
  if (!validateWebApplicationChecks(JSON.parse(generation.resultJson).checks)) {
    return { ok: true, generationId, status: 'checks_missing' };
  }
  return receipt(generationId, null);
}

async function start({ db, ownerSubject, generationId, runner }) {
  const generation = await db.prepare(GENERATION).bind(ownerSubject, generationId).first();
  if (!generation) return failure('generation_not_found');
  const { source, sourceSha256, checks } = JSON.parse(generation.resultJson);
  const plan = validateWebApplicationChecks(checks);
  if (!plan) return failure('verification_checks_missing');
  if (!digest(sourceSha256) || await runnerPayloadSha256(encoder.encode(JSON.stringify(source))) !== sourceSha256) {
    return failure('storage_inconsistent');
  }
  if (!runner?.token || !HEAD.test(runner.expectedHeadSha ?? '')) return failure('verification_unavailable');

  const github = createGitHubWebApplicationRunnerClient({ token: runner.token, expectedHeadSha: runner.expectedHeadSha });
  const [publicKey, authorizationKey] = await Promise.all([
    importWebAppPublicKey(runner.jobPublicKey), importWebAppAuthorizationKey(runner.authorizationKey),
  ]);
  const ticket = crypto.randomUUID();
  let job;
  try {
    job = await encodeWebAppJob({ publicKey, authorizationKey, ticket, source, checks: plan,
      resultPublicKeySpki: runner.resultPublicKey });
  } catch (error) {
    if (error instanceof RangeError) return failure('verification_payload_too_large');
    throw error;
  }
  const claim = await db.prepare(CLAIM).bind(ownerSubject, generationId, ticket,
    runner.expectedHeadSha, job.jobSha256, sourceSha256).first();
  if (!claim) return receipt(generationId, await db.prepare(READ).bind(ownerSubject, generationId).first());

  let runId = null;
  try { runId = await github.dispatch({ ticket, input: job.input }); } catch (_) { /* outcome may be ambiguous */ }
  const status = runId === null ? 'review_required' : 'submitted';
  const changed = await db.prepare(DISPATCHED).bind(ownerSubject, generationId, ticket, status, runId).first();
  if (!changed) return failure('storage_unavailable');
  return { ok: true, generationId, status };
}

function sanitizedAttempts(attempts, sourceSha256) {
  if (!Array.isArray(attempts) || attempts.length > 4 || (attempts.length && attempts[0]?.sourceSha256 !== sourceSha256)) return null;
  const clean = [];
  for (const attempt of attempts) {
    const { status, diagnosis, sourceSha256, checkIndex, checks } = attempt ?? {};
    if (!['passed', 'code_error', 'unavailable'].includes(status) || !DIAGNOSIS.test(diagnosis ?? '') || !digest(sourceSha256)) return null;
    const result = { status, diagnosis, sourceSha256 };
    if (Number.isInteger(checkIndex) && checkIndex >= 0 && checkIndex < 16) result.checkIndex = checkIndex;
    if (Number.isInteger(checks) && checks >= 1 && checks <= 16) result.checks = checks;
    const model = attempt.repairProvenance?.reportedModel;
    if (typeof model === 'string' && model.length > 0 && model.length <= 200) result.repairModel = model;
    clean.push(result);
  }
  return clean;
}

async function validateResult(value, originalSha256) {
  const { status, diagnosis, attempts, source, artifact } = value ?? {};
  if (!['verified', 'failed', 'unavailable'].includes(status) || !DIAGNOSIS.test(diagnosis ?? '')) throw new Error('Bad runner status');
  const safe = sanitizedAttempts(attempts, originalSha256);
  if (!safe) throw new Error('Bad runner attempts');
  if (status !== 'verified') return { status, receiptJson: JSON.stringify({ diagnosis, attempts: safe }) };

  const sourceJson = JSON.stringify(source);
  const normalized = parseGeneratedWebApplication(sourceJson);
  if (!normalized || JSON.stringify(normalized) !== sourceJson || encoder.encode(sourceJson).byteLength > 65536 ||
      safe.at(-1)?.status !== 'passed' || safe.at(-1).sourceSha256 !== artifact?.sourceSha256 ||
      await runnerPayloadSha256(encoder.encode(sourceJson)) !== artifact.sourceSha256 || !digest(artifact.sha256)) {
    throw new Error('Bad verified source');
  }
  const zip = decodeRunnerBase64(artifact.zip, ZIP_LIMIT * 4 / 3);
  if (zip.byteLength < 22 || zip.byteLength > ZIP_LIMIT ||
      new DataView(zip.buffer).getUint32(0, true) !== 0x04034b50 || await runnerPayloadSha256(zip) !== artifact.sha256) {
    throw new Error('Bad runner ZIP');
  }
  return { status, sourceJson, zipSha256: artifact.sha256, zip,
    receiptJson: JSON.stringify({ diagnosis, attempts: safe, sourceSha256: artifact.sourceSha256, zipSha256: artifact.sha256 }) };
}

async function collect({ db, ownerSubject, generationId, row, runner }) {
  if (!runner?.token || !runner.resultPrivateKey || !runner.authorizationKey) return failure('verification_unavailable');
  const github = createGitHubWebApplicationRunnerClient({ token: runner.token, expectedHeadSha: row.headSha });
  const remote = await github.readResult(row.runId);
  if (remote.status === 'pending') return receipt(generationId, row);
  const importId = crypto.randomUUID();
  const claim = await db.prepare(IMPORT).bind(ownerSubject, generationId, row.runId, importId).first();
  if (!claim) return receipt(generationId, await db.prepare(READ).bind(ownerSubject, generationId).first());

  let outcome;
  try {
    if (remote.status === 'failed') {
      outcome = { status: 'unavailable', receiptJson: JSON.stringify({ diagnosis: 'runner_failed', attempts: [] }) };
    } else {
      const [packet, privateKey, authorizationKey] = await Promise.all([
        github.downloadArchive(remote), importWebAppPrivateKey(runner.resultPrivateKey),
        importWebAppAuthorizationKey(runner.authorizationKey),
      ]);
      const value = await decodeWebAppResult({ privateKey, authorizationKey, ticket: row.ticket, packet, jobSha256: row.jobSha256 });
      outcome = await validateResult(value, row.sourceSha256);
    }
  } catch (_) {
    // The lease permits another retrieval attempt after a transient error. Only
    // the current lease holder can ever commit the verified result.
    return failure('verification_unavailable');
  }
  await db.prepare(FINISH).bind(ownerSubject, generationId, importId, outcome.status, outcome.receiptJson,
    outcome.sourceJson ?? null, outcome.zipSha256 ?? null, outcome.zip?.buffer ?? null).first();
  return receipt(generationId, await db.prepare(READ).bind(ownerSubject, generationId).first());
}

export async function advanceWebApplicationVerification({ db, ownerSubject, request, runner }) {
  const { generationId } = request;
  if (Object.keys(request).length !== 1 || !validId(generationId)) return failure('invalid_request');
  const row = await db.prepare(READ).bind(ownerSubject, generationId).first();
  if (!row) return start({ db, ownerSubject, generationId, runner });
  if (row.status === 'submitted' || (row.status === 'importing' && row.age >= 60)) {
    return collect({ db, ownerSubject, generationId, row, runner });
  }
  return receipt(generationId, row);
}

export async function readWebApplicationZip({ db, ownerSubject, generationId }) {
  if (!validId(generationId)) return failure('invalid_request');
  const row = await db.prepare(`SELECT zip_bytes AS bytes, zip_sha256 AS sha256 FROM web_app_verifications
    WHERE owner_subject = ?1 AND generation_id = ?2 AND status = 'verified'`).bind(ownerSubject, generationId).first();
  if (!row || !digest(row.sha256)) return failure('generation_not_found');
  const blob = row.bytes;
  const bytes = blob instanceof ArrayBuffer ? new Uint8Array(blob) :
    blob instanceof Uint8Array ? blob : Array.isArray(blob) ? Uint8Array.from(blob) : null;
  if (!bytes || bytes.byteLength < 22 || bytes.byteLength > ZIP_LIMIT || await runnerPayloadSha256(bytes) !== row.sha256) {
    return failure('storage_unavailable');
  }
  return { ok: true, bytes };
}
