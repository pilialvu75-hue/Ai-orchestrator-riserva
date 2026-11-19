import { createHash } from 'node:crypto';
import { validateWebApplicationChecks } from './web_application_checks.mjs';

const PATH = /^(?:[a-z0-9][a-z0-9_-]*\/){0,3}[a-z0-9][a-z0-9_-]*\.(?:html|css|js|mjs|json|txt|md)$/;
const MAX_SOURCE_BYTES = 65536;
const MAX_REPAIRS = 3;

function validText(value, max) {
  return typeof value === 'string' && value.length > 0 && value.length <= max && value.isWellFormed();
}

export function readVerificationInput(input) {
  const { source, checks } = input ?? {};
  const plan = validateWebApplicationChecks(checks);
  if (!Array.isArray(source?.files) || source.files.length === 0 || source.files.length > 12 || !plan) return null;
  if (Buffer.byteLength(JSON.stringify(source)) > MAX_SOURCE_BYTES) return null;

  const assets = new Map();
  for (const file of source.files) {
    const { path, content } = file ?? {};
    if (!validText(path, 100) || !PATH.test(path) || assets.has(path) ||
        !validText(content, MAX_SOURCE_BYTES) || content.includes('\0')) return null;
    assets.set(path, content);
  }
  if (!assets.has('index.html')) return null;

  return { assets, checks: plan };
}

// A trusted test plan stays fixed across repairs. Infrastructure failure and
// malformed repair output stop the cycle. Only a code failure permits repair.
export async function verifyAndRepairWebApplication({ source, checks, verify, repair }) {
  let candidate = source;
  let repairProvenance = null;
  let repairs = 0;
  const attempts = [];
  const finish = (status, diagnosis) => ({ status, diagnosis, attempts, source: candidate });

  while (true) {
    const input = readVerificationInput({ source: candidate, checks });
    if (!input) return finish('failed', 'invalid_application_or_test_plan');
    const sourceSha256 = createHash('sha256').update(JSON.stringify(candidate)).digest('hex');

    let result;
    try { result = await verify(input); } catch (_) {
      return finish('unavailable', 'verification_infrastructure');
    }
    attempts.push({ sourceSha256, ...result, ...(repairProvenance ? { repairProvenance } : {}) });
    if (result.status === 'passed') return finish('verified', 'checks_passed');
    if (result.status !== 'code_error') return finish('unavailable', result.diagnosis);
    if (!repair || repairs === MAX_REPAIRS) return finish('failed', result.diagnosis);

    let replacement;
    try { replacement = await repair({ source: candidate, diagnosis: result.diagnosis, checkIndex: result.checkIndex }); }
    catch (_) { return finish('unavailable', 'repair_provider_unavailable'); }
    const revised = replacement?.source;
    if (!readVerificationInput({ source: revised, checks })) return finish('failed', 'invalid_repair');
    if (JSON.stringify(candidate) === JSON.stringify(revised)) return finish('failed', 'unchanged_repair');

    candidate = revised;
    repairProvenance = replacement.provenance;
    repairs++;
  }
}
