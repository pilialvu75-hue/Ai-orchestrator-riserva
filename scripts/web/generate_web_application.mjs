import { validateWebApplicationChecks } from './web_application_checks.mjs';
import { normalizeWebApplicationRuntime } from './web_application_runtime_schema.mjs';
import { WEB_RUNNER_TICKET as GENERATION_ID } from './web_runner_envelope.mjs';
export const MAX_WEB_APP_PROMPT_CHARACTERS = 8000;
export const WEB_APP_USER_DAILY_LIMIT = 10;
export const WEB_APP_GLOBAL_DAILY_LIMIT = 72;
// The private owner receives the entire currently configured no-cost quota.
// Provider Cloudflare Free/Neurons availability may still be lower.
export const WEB_APP_ADMIN_DAILY_LIMIT = WEB_APP_GLOBAL_DAILY_LIMIT;
const QUOTA_WINDOW_SECONDS = 86400;

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
const RECORD_INSTRUCTION = `When the user needs server persistence, include a runtime object with kind "records" and
collections, each with name and fields. Fields map lowercase names to text, integer, boolean, or date.
The preview supplies window.aivexusData.request({ action, collection, recordId, version, data, after }).
Actions are list, create, update and delete. A list returns records and nextRecordId. Each record has
recordId, version and data. Create takes recordId (from window.aivexusData.newRecordId()) and data. Update needs
recordId, the last version and the full data. Delete needs recordId and the last version. The request
returns JSON or rejects with a safe error code. Use only the fields applicable to each action.
If the app requests the public GitHub repository integration, include integrations: ["github_repository"]
in runtime and call window.aivexusData.integration("github_repository"). Never place credentials in source.
Amounts of money should be stored as an integer number of cents. Omit runtime for an offline app.`;

// Count reservations atomically before inference, including failed attempts.
export function webGenerationQuotaPredicate(userOffset, globalOffset) {
  return `NOT EXISTS (
    SELECT 1 FROM web_app_generations WHERE owner_subject = ?1 AND created_at >= unixepoch() - 86400
    LIMIT 1 OFFSET ?${userOffset}
  ) AND NOT EXISTS (
    SELECT 1 FROM web_app_generations WHERE created_at >= unixepoch() - 86400
    LIMIT 1 OFFSET ?${globalOffset}
  )`;
}

const CLAIM = `INSERT INTO web_app_generations
  (owner_subject, generation_id, prompt_sha256, status)
  SELECT ?1, ?2, ?3, 'generating' WHERE ${webGenerationQuotaPredicate(4, 5)}
  ON CONFLICT(owner_subject, generation_id) DO NOTHING
  RETURNING generation_id`;
// Admin privileges require an exact match against a trusted *server-side*
// Cloudflare Access subject. Never infer admin role from browser headers or a
// URL and never turn off the global free-tier budget gate.
export function generationLimits(ownerSubject, adminSubject) {
  const admin = typeof adminSubject === 'string' &&
    adminSubject.length > 0 && adminSubject.length <= 256 &&
    adminSubject === ownerSubject;
  return {
    admin,
    userLimit: admin ? WEB_APP_ADMIN_DAILY_LIMIT : WEB_APP_USER_DAILY_LIMIT,
    globalLimit: WEB_APP_GLOBAL_DAILY_LIMIT,
  };
}

// Same rolling 24-hour window and same D1 table as the atomic claim gate.
// Count all reservations including failed attempts, since inference may use
// free AI resources even when the generated source is not valid.
const QUOTA = `SELECT
 (SELECT COUNT(*) FROM web_app_generations
  WHERE owner_subject = ?1 AND created_at >= unixepoch() - ${QUOTA_WINDOW_SECONDS}) AS userUsed,
 (SELECT COUNT(*) FROM web_app_generations
  WHERE created_at >= unixepoch() - ${QUOTA_WINDOW_SECONDS}) AS globalUsed,
 (SELECT MIN(created_at) FROM web_app_generations
  WHERE owner_subject = ?1 AND created_at >= unixepoch() - ${QUOTA_WINDOW_SECONDS}) AS oldestUser,
 (SELECT MIN(created_at) FROM web_app_generations
  WHERE created_at >= unixepoch() - ${QUOTA_WINDOW_SECONDS}) AS oldestGlobal`;

export async function readWebApplicationQuota({ db, ownerSubject, adminSubject }) {
  if (typeof ownerSubject !== 'string' || !ownerSubject) {
    return { ok: false, reason: 'invalid_request' };
  }
  const limits = generationLimits(ownerSubject, adminSubject);
  const row = await db.prepare(QUOTA).bind(ownerSubject).first();
  if (!row) return { ok: false, reason: 'storage_unavailable' };
  const userUsed = Number(row.userUsed);
  const globalUsed = Number(row.globalUsed);
  const oldestUser = row.oldestUser === null ? null : Number(row.oldestUser);
  const oldestGlobal = row.oldestGlobal === null ? null : Number(row.oldestGlobal);
  if (![userUsed, globalUsed].every(n => Number.isSafeInteger(n) && n >= 0) ||
      (oldestUser !== null && !Number.isSafeInteger(oldestUser)) ||
      (oldestGlobal !== null && !Number.isSafeInteger(oldestGlobal))) {
    return { ok: false, reason: 'storage_inconsistent' };
  }
  const userRemaining = Math.max(0, limits.userLimit - userUsed);
  const globalRemaining = Math.max(0, limits.globalLimit - globalUsed);
  const remaining = Math.min(userRemaining, globalRemaining);
  const waitUntil = remaining !== 0 ? null : Math.max(
    userRemaining === 0 && oldestUser !== null ? oldestUser + QUOTA_WINDOW_SECONDS : 0,
    globalRemaining === 0 && oldestGlobal !== null ? oldestGlobal + QUOTA_WINDOW_SECONDS : 0,
  );
  return {
    ok: true, userLimit: limits.userLimit, userUsed, userRemaining,
    globalLimit: limits.globalLimit, globalUsed, globalRemaining,
    tier: limits.admin ? 'administrator' : 'standard',
    remaining, windowSeconds: QUOTA_WINDOW_SECONDS,
    nextAvailableAt: waitUntil ? new Date(waitUntil * 1000).toISOString() : null,
    scope: 'aivexus_reservations',
  };
}

// A verified project is a reusable snapshot of the *same owner's* exact
// request. Returning its existing generation id avoids a new inference call,
// a new reservation and redundant verification; it is not a cross-user cache
// and it does not imply that Module Library packages are already available.
const VERIFIED_REUSE = `SELECT g.generation_id AS generationId
  FROM web_app_generations g
  INNER JOIN web_app_verifications v
    ON v.owner_subject = g.owner_subject AND v.generation_id = g.generation_id
  WHERE g.owner_subject = ?1 AND g.prompt_sha256 = ?2
    AND g.status = 'generated' AND v.status = 'verified'
    AND v.source_json IS NOT NULL AND v.zip_bytes IS NOT NULL
  ORDER BY g.created_at DESC LIMIT 1`;

export async function findVerifiedWebApplicationReuse({ db, ownerSubject, promptSha256 }) {
  if (typeof ownerSubject !== 'string' || !ownerSubject ||
      typeof promptSha256 !== 'string' ||
      !/^[a-f0-9]{64}$/.test(promptSha256)) {
    return { ok: false, reason: 'invalid_request' };
  }
  const row = await db.prepare(VERIFIED_REUSE).bind(ownerSubject, promptSha256).first();
  return { ok: true, found: !!row, ...(row ? { generationId: row.generationId } : {}) };
}

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

// Match Flutter TextField.maxLength: count user-perceived characters
// (grapheme clusters), not UTF-16 code units. Validate before reserving quota.
function cleanGenerationPrompt(value) {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  if (!text || !text.isWellFormed()) return null;
  let count = 0;
  for (const _ of new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(text)) {
    if (++count > MAX_WEB_APP_PROMPT_CHARACTERS) return null;
  }
  return text;
}

export function parseResponse(output) {
  if (typeof output !== 'string') return null;
  const fenced = /^```(?:json)?\s*\n([\s\S]+)\n```$/i.exec(output);
  try { return JSON.parse(fenced ? fenced[1] : output); } catch (_) { return null; }
}

export function parseGeneratedWebApplication(output) {
  return normalizeSource(parseResponse(output));
}

export function normalizeSource(parsed) {

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
  if (parsed.runtime === undefined) return { title, requirements, files };
  const runtime = normalizeWebApplicationRuntime(parsed.runtime);
  return runtime && !paths.has('aivexus-runtime.json') ? { title, requirements, files, runtime } : null;
}

export function receipt(generationId, status, saved) {
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
  return receipt(generationId, row.status, row.resultJson);
}

export async function generateWebApplication({ request, ownerSubject, adminSubject, db, infer }) {
  const { generationId, prompt, builderRouteId } = request;
  const brief = cleanGenerationPrompt(prompt);
  const isManual = builderRouteId !== undefined;
  if (Object.keys(request).length !== (isManual ? 3 : 2) ||
      (isManual && (typeof builderRouteId !== 'string' ||
        !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(builderRouteId))) ||
      typeof generationId !== 'string' ||
      !GENERATION_ID.test(generationId) || !brief || !brief.isWellFormed()) {
    return { ok: false, reason: 'invalid_request' };
  }

  const promptSha256 = await sha256Text(brief);
  const previous = await db.prepare(READ).bind(ownerSubject, generationId).first();
  if (previous) {
    if (previous.promptSha256 !== promptSha256) return { ok: false, reason: 'generation_conflict' };
    return receipt(generationId, previous.status, previous.resultJson);
  }
  if (!infer) return { ok: false, reason: 'generation_unavailable' };
  // Trial credits are reserved for the signed Access administrator only.
  // Deny before D1 quota reservation even when the route itself is enabled.
  const isAdmin = typeof adminSubject === 'string' && adminSubject.length > 0 &&
    ownerSubject === adminSubject;
  // Reject inaccessible or non-approved trial routes BEFORE the D1 reservation.
  if (isManual && (!isAdmin || infer.supportsBuilderRoute?.(builderRouteId) !== true)) {
    return { ok: false, reason: 'generation_model_unavailable' };
  }

  const limits = generationLimits(ownerSubject, adminSubject);
  const claim = await db.prepare(CLAIM).bind(
    ownerSubject, generationId, promptSha256, limits.userLimit - 1,
    limits.globalLimit - 1,
  ).first();
  if (!claim) {
    const winner = await db.prepare(READ).bind(ownerSubject, generationId).first();
    if (!winner) return { ok: false, reason: 'generation_quota_exceeded' };
    if (winner.promptSha256 !== promptSha256) {
      return { ok: false, reason: 'generation_conflict' };
    }
    return receipt(generationId, winner.status, winner.resultJson);
  }

  const inference = await infer([
    { role: 'system', content: INSTRUCTION + '\n' + RECORD_INSTRUCTION },
    { role: 'user', content: brief },
  ], isManual ? builderRouteId : null).catch(() => ({ ok: false }));
  const reply = inference.ok ? parseResponse(inference.text) : null;
  return saveWebApplicationCandidate({ db, ownerSubject, generationId, inference,
    source: normalizeSource(reply), checks: validateWebApplicationChecks(reply?.checks) });
}

export async function saveWebApplicationCandidate({ db, ownerSubject, generationId, inference, source, checks }) {
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
    return receipt(generationId, row.status, row.resultJson);
  }
  return receipt(generationId, status, resultJson);
}
