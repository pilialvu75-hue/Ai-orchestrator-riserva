/**
 * Aivexus Web ONLY: safely enroll two NVIDIA free-prototype models.
 * No authorization headers, credentials, secrets, endpoints, or routing
 * JSON are ever printed. Protected GitHub Environment required.
 *
 * Steps: read_only -> enable_manual. Model entitlement is NOT implied
 * by configuration: a separate user-initiated synthetic self-test is needed.
 */
import { readFile } from 'node:fs/promises';

const gate = 'WEB_LARGE_NIM_P0';
const expected = [
  { id: 'kimi-k26-orchestrator', model: 'moonshotai/kimi-k2.6' },
  { id: 'deepseek-v41-flash-orchestrator', model: 'deepseek-ai/deepseek-v4.1-flash' },
];
const ultraId = 'nemotron-ultra-orchestrator';
const apiEndpoint = 'https://integrate.api.nvidia.com/v1/chat/completions';
const variable = 'CANTIERE_CLOUD_ROUTES_JSON';
const requestFile = '.airlab/deploy/large-nim-models-request.json';

function abort(reason) {
  console.error(gate + '_BLOCKED_' + reason);
  throw new Error('Protected enrollment halted (sanitized).');
}
function ensure(condition, reason) { if (!condition) abort(reason); }
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
let request;
try { request = JSON.parse(await readFile(requestFile, 'utf8')); }
catch { abort('REQUEST_INVALID'); }
ensure(request?.schemaVersion === 1 &&
  ['read_only', 'enable_manual'].includes(request.operation) &&
  request.confirmation === 'OWNER_APPROVED_TWO_NVIDIA_NIM_PROTOTYPE_MODELS' &&
  request.environment === 'web-private-production' &&
  request.models?.length === 2 &&
  request.models[0] === expected[0].model &&
  request.models[1] === expected[1].model,
  'REQUEST_NOT_AUTHORIZED');

const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
const apiToken = process.env.CLOUDFLARE_API_TOKEN;
const projectName = process.env.CLOUDFLARE_PAGES_PROJECT;
ensure(accountId && apiToken && projectName, 'CLOUDFLARE_CREDENTIALS_MISSING');
const url = 'https://api.cloudflare.com/client/v4/accounts/' +
  encodeURIComponent(accountId) + '/pages/projects/' +
  encodeURIComponent(projectName);

async function cloudflare(method, body) {
  let response;
  try {
    response = await fetch(url, {
      method,
      headers: {
        Authorization: 'Bearer ' + apiToken,
        Accept: 'application/json',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(25000),
    });
  } catch { abort('API_UNREACHABLE'); }
  if (!response.ok) abort('API_HTTP_' + response.status);
  let parsed;
  try { parsed = await response.json(); }
  catch { abort('API_INVALID_RESPONSE'); }
  ensure(parsed?.success === true && isObject(parsed.result), 'API_REJECTED');
  return parsed.result;
}

function productionVars(project) {
  ensure(project?.name === projectName, 'WRONG_PROJECT');
  const vars = project?.deployment_configs?.production?.env_vars;
  ensure(isObject(vars), 'PRODUCTION_VARS_UNREADABLE');
  return vars;
}
function decodeRoutes(vars) {
  const env = vars[variable];
  ensure(env?.type === 'plain_text' && typeof env.value === 'string',
    'ROUTING_VARIABLE_UNREADABLE');
  let config;
  try { config = JSON.parse(env.value); }
  catch { abort('ROUTES_INVALID_JSON'); }
  ensure(isObject(config) && Array.isArray(config.orchestration),
    'ORCHESTRATION_ROUTES_MISSING');
  return config;
}
function safeBase(vars, config) {
  const matches = config.orchestration.filter((r) => r?.id === ultraId);
  ensure(matches.length === 1, 'ULTRA_ROUTE_MISSING_OR_DUPLICATE');
  const ultra = matches[0];
  ensure(ultra.model === 'nvidia/nemotron-3-ultra-550b-a55b',
    'ULTRA_MODEL_UNEXPECTED');
  ensure(ultra.endpoint === apiEndpoint, 'ULTRA_ENDPOINT_UNEXPECTED');
  const key = ultra.apiKeySecret;
  ensure(typeof key === 'string' &&
    /^[A-Z][A-Z0-9_]{2,63}$/.test(key) &&
    vars[key]?.type === 'secret_text',
    'NVIDIA_BINDING_NOT_ENCRYPTED');
  const seen = new Set();
  for (const route of config.orchestration) {
    ensure(isObject(route) && typeof route.id === 'string' &&
      !seen.has(route.id), 'AMBIGUOUS_ROUTES');
    seen.add(route.id);
  }
  for (const item of expected) {
    const prior = config.orchestration.find((r) => r.id === item.id);
    if (!prior) continue;
    ensure(
      prior.model === item.model &&
      prior.endpoint === apiEndpoint &&
      prior.apiKeySecret === key &&
      prior.manualOnly === true &&
      prior.selfTestFree === true,
      'CONFLICTING_PREVIOUS_MODEL_ROUTE',
    );
  }
  return key;
}

const beforeProject = await cloudflare('GET');
const beforeVars = productionVars(beforeProject);
const beforeRoutes = decodeRoutes(beforeVars);
const key = safeBase(beforeVars, beforeRoutes);
if (request.operation === 'read_only') {
  console.log(gate + '_READ_ONLY_PREFLIGHT_PASS');
  process.exit(0);
}
const next = structuredClone(beforeRoutes);
let inserted = 0;
for (const item of expected) {
  if (next.orchestration.some((r) => r.id === item.id)) continue;
  // The free-prototype models must never be picked by AUTO, even when
  // Nemotron fails. One user-directed synthetic test is required per model.
  next.orchestration.push({
    id: item.id,
    endpoint: apiEndpoint,
    model: item.model,
    apiKeySecret: key,
    manualOnly: true,
    selfTestFree: true,
  });
  inserted++;
}
if (inserted === 0) {
  console.log(gate + '_ALREADY_ENROLLED');
  process.exit(0);
}
ensure(inserted === 2, 'PARTIAL_ROUTE_INSERTION_UNEXPECTED');
const beforeText = beforeVars[variable].value;
const changedText = JSON.stringify(next);
const payload = (value) => ({
  deployment_configs: {
    production: {
      env_vars: {
        [variable]: { type: 'plain_text', value },
      },
    },
  },
});
console.log(gate + '_PREFLIGHT_PASS');
await cloudflare('PATCH', payload(changedText));
let verified = false;
try {
  for (let attempt = 0; attempt < 5; attempt++) {
    const current = productionVars(await cloudflare('GET'));
    ensure(equal(Object.keys(beforeVars).sort(), Object.keys(current).sort()),
      'BINDING_NAMES_CHANGED');
    for (const name of Object.keys(beforeVars)) {
      if (name === variable) continue;
      ensure(current[name]?.type === beforeVars[name]?.type,
        'BINDING_TYPE_CHANGED');
      if (beforeVars[name]?.type === 'plain_text') {
        ensure(current[name]?.value === beforeVars[name]?.value,
          'UNRELATED_BINDING_CHANGED');
      }
    }
    const currentConfig = decodeRoutes(current);
    safeBase(current, currentConfig);
    if (equal(currentConfig, next)) { verified = true; break; }
    await new Promise((resolve) => setTimeout(resolve, 1200));
  }
} catch {
  try {
    await cloudflare('PATCH', payload(beforeText));
    console.error(gate + '_ROLLBACK_ATTEMPTED');
  } catch {
    console.error(gate + '_ROLLBACK_FAILED_MANUAL_CHECK_REQUIRED');
  }
  abort('POST_WRITE_CHECK_FAILED');
}
if (!verified) {
  try {
    await cloudflare('PATCH', payload(beforeText));
    console.error(gate + '_ROLLBACK_ATTEMPTED');
  } catch {
    console.error(gate + '_ROLLBACK_FAILED_MANUAL_CHECK_REQUIRED');
  }
  abort('POST_WRITE_NOT_VISIBLE');
}
console.log(gate + '_BOTH_MANUAL_ROUTES_VERIFIED');
console.log('NEXT: private Pages deploy and user-initiated synthetic Self-Test per model.');
