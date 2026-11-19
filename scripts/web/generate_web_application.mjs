const GENERATION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const FILE_PATH = /^(?:[a-z0-9][a-z0-9_-]*\/){0,3}[a-z0-9][a-z0-9_-]*\.(?:html|css|js|mjs|json|txt|md)$/;
const INSTRUCTION = `Generate an original, self-contained browser application matching the user's brief.
Return a single JSON object with title, requirements (an array of user-visible behavior descriptions),
and files (an array of objects with path and content). The entry point is index.html.
Choose the other file names and number of files based on the brief. Use lowercase portable paths,
local dependencies only, no package installation, secrets or external network requests.
Keep the application compact enough to return all source within the response limit.`;

const CLAIM = `INSERT INTO web_app_generations
  (owner_subject, generation_id, prompt_sha256, status)
  VALUES (?1, ?2, ?3, 'generating')
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

function validateSource(output) {
  if (typeof output !== 'string') return null;
  const fenced = /^```(?:json)?\s*\n([\s\S]+)\n```$/i.exec(output);
  let parsed;
  try { parsed = JSON.parse(fenced ? fenced[1] : output); } catch (_) { return null; }

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

function receipt(generationId, status, saved) {
  if (status !== 'generated') return { ok: true, generationId, status };
  const { source, sourceSha256, provenance } = JSON.parse(saved);
  return {
    ok: true, generationId, status, sourceSha256, provenance,
    title: source.title, requirements: source.requirements,
    paths: source.files.map(file => file.path),
  };
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
    return receipt(generationId, previous.status, previous.resultJson);
  }
  if (!infer) return { ok: false, reason: 'generation_unavailable' };

  const claim = await db.prepare(CLAIM).bind(ownerSubject, generationId, promptSha256).first();
  if (!claim) {
    const winner = await db.prepare(READ).bind(ownerSubject, generationId).first();
    if (!winner || winner.promptSha256 !== promptSha256) {
      return { ok: false, reason: 'generation_conflict' };
    }
    return receipt(generationId, winner.status, winner.resultJson);
  }

  let resultJson = null;
  const inference = await infer([
    { role: 'system', content: INSTRUCTION },
    { role: 'user', content: brief },
  ]).catch(() => ({ ok: false }));
  const source = inference.ok ? validateSource(inference.text) : null;
  if (source) {
    const { model, reportedModel, provider, routeId, tokensGenerated } = inference;
    const provenance = { model, reportedModel, provider, routeId, tokensGenerated };
    const sourceSha256 = await sha256Text(JSON.stringify(source));
    const serialized = JSON.stringify({ source, sourceSha256, provenance });
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
