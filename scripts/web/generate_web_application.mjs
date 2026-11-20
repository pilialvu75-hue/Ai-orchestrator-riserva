import { validateWebApplicationChecks } from './web_application_checks.mjs';
import { WEB_RUNNER_TICKET as GENERATION_ID } from './web_runner_envelope.mjs';
const FILE_PATH = /^(?:[a-z0-9][a-z0-9_-]*\/){0,3}[a-z0-9][a-z0-9_-]*\.(?:html|css|js|mjs|json|txt|md)$/;
const INSTRUCTION = `Generate an original, self-contained browser application matching the user's brief.
Return a single JSON object with title, requirements (an array of user-visible behavior descriptions),
files (an array of objects with path and content), and checks (up to 16 browser actions).
Each check contains action and selector, and value for text or fill. Use click to activate controls,
fill to enter text, and text to assert visible text. Include an assertion that verifies a behavior
requested by the user after interacting with it. The entry point is index.html.
Choose the other file names and number of files based on the brief. Use lowercase portable paths,
local dependencies only, no package installation, secrets or external network requests.
Keep the application compact enough to return all source within the response limit.`;

// Count reservations atomically before inference, including failed attempts.
export const WEB_GENERATION_QUOTA_AVAILABLE = `NOT EXISTS (
    SELECT 1 FROM web_app_generations WHERE owner_subject = ?1 AND created_at >= unixepoch() - 86400
    LIMIT 1 OFFSET 5
  ) AND NOT EXISTS (
    SELECT 1 FROM web_app_generations WHERE created_at >= unixepoch() - 86400
    LIMIT 1 OFFSET 23
  )`;
const CLAIM = `INSERT INTO web_app_generations
  (owner_subject, generation_id, prompt_sha256, status)
  SELECT ?1, ?2, ?3, 'generating' WHERE ${WEB_GENERATION_QUOTA_AVAILABLE}
  ON CONFLICT(owner_subject, generation_id) DO NOTHING
  RETURNING generation_id`;
const READ = `SELECT CASE WHEN status = 'generating' AND unixepoch() - created_at >= 180
    THEN 'interrupted' ELSE status END AS status,
    prompt_sha256 AS promptSha256, result_json AS resultJson
  FROM web_app_generations WHERE owner_subject = ?1 AND generation_id = ?2`;
const FINISH = `UPDATE web_app_generations SET status = ?3, result_json = ?4
  WHERE owner_subject = ?1 AND generation_id = ?2 AND status = 'generating'
    AND unixepoch() - created_at < 180
  RETURNING generation_id`;

const encoder = new TextEncoder();

async function sha256Text(text) {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(text));
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}

function cleanText(value, max) {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  return text && text.length <= max ? text : null;
}

export function parseWebModelJson(output) {
  if (typeof output !== 'string') return null;
  const fenced = /^```(?:json)?\s*\n([\s\S]+)\n```$/i.exec(output);
  try { return JSON.parse(fenced ? fenced[1] : output); } catch (_) { return null; }
}

export function parseGeneratedWebApplication(output) {
  return normalizeWebApplicationSource(parseWebModelJson(output));
}

export function normalizeWebApplicationSource(parsed) {

  const title = cleanText(parsed?.title, 100);
  if (!title || !Array.isArray(parsed.requirements) || parsed.requirements.length < 1 ||
      parsed.requirements.length > 12 || !Array.isArray(parsed.files) ||
      parsed.files.length < 1 || parsed.files.length > 12) return null;
  const requirements = parsed.requirements.map(requirement => cleanText(requirement, 250));
  if (requirements.some(requirement => !requirement)) return null;

  const paths = new Set();
  const files = [];
  for (const file of parsed.files) {
    const { path, content } = file ?? {};
    if (typeof path !== 'string' || path.length > 100 || !FILE_PATH.test(path) ||
        paths.has(path) || typeof content !== 'string' || !content.trim() ||
        content.includes('\0') || !content.isWellFormed()) return null;
    paths.add(path);
    files.push({ path, content });
  }
  if (!paths.has('index.html')) return null;
  files.sort((a, b) => a.path < b.path ? -1 : a.path === b.path ? 0 : 1);
  return { title, requirements, files };
}

export function webApplicationGenerationReceipt(generationId, status, saved) {
  if (status !== 'generated') return { ok: true, generationId, status };
  const { source, sourceSha256, provenance } = JSON.parse(saved);
  return {
    ok: true, generationId, status, sourceSha256, provenance,
    title: source.title, requirements: source.requirements,
    paths: source.files.map(file => file.path),
  };
}

export async function readWebApplicationGeneration({ db, ownerSubject, generationId }) {
  if (!GENERATION_ID.test(generationId ?? '')) return { ok: false, reason: 'invalid_request' };
  const row = await db.prepare(READ).bind(ownerSubject, generationId).first();
  if (!row) return { ok: false, reason: 'generation_not_found' };
  return webApplicationGenerationReceipt(generationId, row.status, row.resultJson);
}

export async function generateWebApplication({ request, ownerSubject, db, infer }) {
  const { generationId, prompt } = request;
  const brief = cleanText(prompt, 1200);
  if (Object.keys(request).length !== 2 || typeof generationId !== 'string' ||
      !GENERATION_ID.test(generationId) || !brief || !brief.isWellFormed()) {
    return { ok: false, reason: 'invalid_request' };
  }

  const promptSha256 = await sha256Text(brief);
  const previous = await db.prepare(READ).bind(ownerSubject, generationId).first();
  if (previous) {
    if (previous.promptSha256 !== promptSha256) return { ok: false, reason: 'generation_conflict' };
    return webApplicationGenerationReceipt(generationId, previous.status, previous.resultJson);
  }
  if (!infer) return { ok: false, reason: 'generation_unavailable' };

  const claim = await db.prepare(CLAIM).bind(ownerSubject, generationId, promptSha256).first();
  if (!claim) {
    const winner = await db.prepare(READ).bind(ownerSubject, generationId).first();
    if (!winner) return { ok: false, reason: 'generation_quota_exceeded' };
    if (winner.promptSha256 !== promptSha256) {
      return { ok: false, reason: 'generation_conflict' };
    }
    return webApplicationGenerationReceipt(generationId, winner.status, winner.resultJson);
  }

  const inference = await infer([
    { role: 'system', content: INSTRUCTION },
    { role: 'user', content: brief },
  ]).catch(() => ({ ok: false }));
  const reply = inference.ok ? parseWebModelJson(inference.text) : null;
  const source = normalizeWebApplicationSource(reply);
  const checks = validateWebApplicationChecks(reply?.checks);
  return saveWebApplicationCandidate({ db, ownerSubject, generationId, source, checks, inference });
}

export async function saveWebApplicationCandidate({ db, ownerSubject, generationId, source, checks, inference }) {
  let resultJson = null;
  if (source) {
    const { model, reportedModel, provider, routeId, tokensGenerated } = inference;
    const provenance = { model, reportedModel, provider, routeId, tokensGenerated };
    const sourceSha256 = await sha256Text(JSON.stringify(source));
    const serialized = JSON.stringify({ source, sourceSha256, provenance, checks });
    if (encoder.encode(serialized).byteLength <= 65536) resultJson = serialized;
  }
  const status = resultJson ? 'generated' : 'failed';
  const written = await db.prepare(FINISH).bind(ownerSubject, generationId, status, resultJson).first();
  if (!written) {
    const row = await db.prepare(READ).bind(ownerSubject, generationId).first();
    if (!row) return { ok: false, reason: 'storage_unavailable' };
    return webApplicationGenerationReceipt(generationId, row.status, row.resultJson);
  }
  return webApplicationGenerationReceipt(generationId, status, resultJson);
}
