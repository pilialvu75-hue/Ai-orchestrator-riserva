import { createGitHubStudioCadRunnerClient } from './github_counter_runner_client.mjs';
import { readWebCadRevision, saveWebCadRevision, WEB_CAD_PROJECT_ID } from './d1_web_cad_revisions.mjs';
import { applyOpenBoxInstruction, parseOpenBoxDescription, validateOpenBoxParameters } from './studio_3d_box_parameters.mjs';
import { WEB_RUNNER_TICKET } from './web_runner_envelope.mjs';
import { decodeRunnerBase64, decodeWebAppResult, encodeWebAppJob, importWebAppAuthorizationKey,
  importWebAppPrivateKey, importWebAppPublicKey } from './web_application_runner_packet.mjs';

const photoAxes = ['width', 'depth', 'height'];
const fail = reason => ({ ok: false, reason });
const validIds = (projectId, revisionId) => WEB_CAD_PROJECT_ID.test(projectId) && WEB_RUNNER_TICKET.test(revisionId);
const keys = ({ ownerSubject, projectId, revisionId }) => [ownerSubject, projectId, revisionId];
const whereJob = 'owner_subject = ?1 AND project_id = ?2 AND revision_id = ?3';
const readJob = (db, args) => db.prepare('SELECT * FROM web_cad_jobs WHERE ' + whereJob).bind(...keys(args)).first();

export async function startWebCadJob({ db, ownerSubject, request, runner,
  githubClient = createGitHubStudioCadRunnerClient }) {
  const { projectId, revisionId, baseRevisionId = null } = request;
  if (!validIds(projectId, revisionId) || (baseRevisionId !== null && !WEB_RUNNER_TICKET.test(baseRevisionId)) ||
      Object.keys(request).some(key => !['projectId', 'revisionId', 'baseRevisionId', 'parameters', 'instruction', 'photoEstimates'].includes(key))) {
    return fail('invalid_request');
  }
  if (!runner?.token || !/^[a-f0-9]{40}$/.test(runner.headSha ?? '')) return fail('cad_unavailable');
  const hasInstruction = Object.hasOwn(request, 'instruction');
  const requestedEstimates = request.photoEstimates ?? [];
  if (!Array.isArray(requestedEstimates) ||
      requestedEstimates.length > photoAxes.length ||
      requestedEstimates.some(axis => !photoAxes.includes(axis)) ||
      (hasInstruction && Object.hasOwn(request, 'photoEstimates'))) return fail('invalid_request');
  let photoEstimates = photoAxes.filter(axis => requestedEstimates.includes(axis));
  if (hasInstruction === Object.hasOwn(request, 'parameters')) return fail('invalid_request');
  let parameters;
  if (hasInstruction) {
    if (baseRevisionId === null) {
      try { parameters = parseOpenBoxDescription(request.instruction); } catch (_) {
        return fail('unsupported_cad_description');
      }
    } else {
      const base = await readWebCadRevision({ db, ownerSubject, projectId, revisionId: baseRevisionId });
      if (!base.ok) return fail('cad_revision_conflict');
      try {
        parameters = applyOpenBoxInstruction(base.manifest.parameters, request.instruction);
        photoEstimates = photoAxes.filter(axis => base.manifest.photoEstimates?.includes(axis));
      } catch (_) {
        return fail('unsupported_cad_instruction');
      }
    }
  } else {
    try { parameters = validateOpenBoxParameters(request.parameters); } catch (_) { return fail('invalid_request'); }
  }

  const args = { ownerSubject, projectId, revisionId };
  const parametersJson = JSON.stringify(parameters);
  const photoEstimatesJson = JSON.stringify(photoEstimates);
  // Release an abandoned local claim after the artifact retention window.
  // Its ticket remains recorded and can never dispatch a second time.
  await db.prepare(`UPDATE web_cad_jobs SET status = 'review_required'
    WHERE owner_subject = ?1 AND status IN ('dispatching','submitted')
      AND created_at <= unixepoch() - 86400`).bind(ownerSubject).run();
  const previous = await readJob(db, args);
  if (previous) {
    return previous.base_revision_id === baseRevisionId && previous.parameters_json === parametersJson && previous.photo_estimates_json === photoEstimatesJson
      ? { ok: true, revisionId, status: previous.status }
      : fail('cad_job_conflict');
  }
  const [publicKey, authorizationKey] = await Promise.all([
    importWebAppPublicKey(runner.jobPublicKey), importWebAppAuthorizationKey(runner.authorizationKey),
  ]);
  const job = await encodeWebAppJob({
    publicKey, authorizationKey, ticket: revisionId, resultPublicKeySpki: runner.resultPublicKey,
    source: { kind: 'cad_open_box', parameters }, checks: [],
  });

  const claim = await db.prepare(`
    INSERT INTO web_cad_jobs
      (owner_subject, project_id, revision_id, base_revision_id, head_sha, job_sha256, parameters_json, photo_estimates_json, status)
    SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'dispatching'
    WHERE (?4 IS NULL AND NOT EXISTS (
        SELECT 1 FROM web_cad_revisions WHERE owner_subject = ?1 AND project_id = ?2
      )) OR (?4 IS NOT NULL AND EXISTS (
        SELECT 1 FROM web_cad_revisions
        WHERE owner_subject = ?1 AND project_id = ?2 AND revision_id = ?4
      ))
    ON CONFLICT DO NOTHING RETURNING revision_id
  `).bind(...keys(args), baseRevisionId, runner.headSha, job.jobSha256, parametersJson, photoEstimatesJson).first();
  if (!claim) return fail('cad_job_conflict');

  let runId = null;
  try {
    runId = await githubClient({ token: runner.token, expectedHeadSha: runner.headSha })
      .dispatch({ ticket: revisionId, input: job.input });
  } catch (_) {
    // The dispatch may have been accepted. Never replay the same ticket.
  }
  const status = runId === null ? 'review_required' : 'submitted';
  const saved = await db.prepare(`UPDATE web_cad_jobs SET status = ?4, run_id = ?5
    WHERE ${whereJob} AND status = 'dispatching' RETURNING status`)
    .bind(...keys(args), status, runId).first();
  return saved ? { ok: true, revisionId, status } : fail('cad_unavailable');
}

export async function collectWebCadJob({ db, ownerSubject, request, runner,
  githubClient = createGitHubStudioCadRunnerClient }) {
  const { projectId, revisionId } = request;
  if (!validIds(projectId, revisionId) || Object.keys(request).length !== 2) return fail('invalid_request');
  const args = { ownerSubject, projectId, revisionId };
  const row = await readJob(db, args);
  if (!row) return fail('cad_job_not_found');
  if (row.status !== 'submitted') return { ok: true, revisionId, status: row.status };
  if (!runner?.token || !runner.resultPrivateKey || !runner.authorizationKey) return fail('cad_unavailable');

  const github = githubClient({ token: runner.token, expectedHeadSha: row.head_sha });
  const remote = await github.readResult(row.run_id);
  if (remote.status === 'pending') return { ok: true, revisionId, status: 'submitted' };
  let status = 'failed';
  if (remote.status === 'ready') {
    const [packet, privateKey, authorizationKey] = await Promise.all([
      github.downloadArchive(remote), importWebAppPrivateKey(runner.resultPrivateKey),
      importWebAppAuthorizationKey(runner.authorizationKey),
    ]);
    const { manifest, scad, stl } = await decodeWebAppResult({
      privateKey, authorizationKey, ticket: revisionId, packet, jobSha256: row.job_sha256,
    });
    const parameters = validateOpenBoxParameters(manifest?.parameters);
    if (JSON.stringify(parameters) !== row.parameters_json) return fail('invalid_cad_result');
    const stored = await saveWebCadRevision({
      db, ...args, baseRevisionId: row.base_revision_id,
      manifest: { ...manifest, photoEstimates: JSON.parse(row.photo_estimates_json) },
      scad: decodeRunnerBase64(scad, 90000), stl: decodeRunnerBase64(stl, 90000),
    });
    if (!stored.ok && (stored.reason !== 'cad_revision_conflict' ||
        !(await readWebCadRevision({ db, ...args })).ok)) return stored;
    status = 'verified';
  }

  await db.prepare(`UPDATE web_cad_jobs SET status = ?4 WHERE ${whereJob} AND status = 'submitted'`)
    .bind(...keys(args), status).run();
  return { ok: true, revisionId, status };
}

export async function findActiveWebCadJob({ db, ownerSubject, request }) {
  const { projectId } = request;
  if (Object.keys(request).length !== 1 || !WEB_CAD_PROJECT_ID.test(projectId)) return fail('invalid_request');
  const row = await db.prepare(`
    SELECT revision_id AS revisionId, status
    FROM web_cad_jobs
    WHERE owner_subject = ?1 AND project_id = ?2 AND status IN ('dispatching','submitted')
      AND created_at > unixepoch() - 86400
  `).bind(ownerSubject, projectId).first();
  return { ok: true, activeJob: row ? { revisionId: row.revisionId, status: row.status } : null };
}
