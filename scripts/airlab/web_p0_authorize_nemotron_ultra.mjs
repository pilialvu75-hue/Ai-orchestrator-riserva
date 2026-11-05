/**
 * Aivexus Web P0 — one-route Cloudflare Pages authorization gate.
 *
 * Executes inside the protected GitHub environment, never in the browser.
 * NEVER print the Pages project JSON, API response bodies, secret references,
 * tokens, account IDs, authorization headers, or the old/new routing JSON.
 * No upstream AI requests are made here.
 */
import { readFile } from 'node:fs/promises';

const gate = 'P0_NEMOTRON_ULTRA_SELF_TEST';
const routeId = 'nemotron-ultra-orchestrator';
const modelId = 'nvidia/nemotron-3-ultra-550b-a55b';
const variableName = 'CANTIERE_CLOUD_ROUTES_JSON';

function stop(reason) {
  console.error(gate + '_BLOCKED:' + reason);
  process.exitCode = 1;
  throw new Error('Fail-closed (sanitized).');
}
function assert(condition, reason) {
  if (!condition) stop(reason);
}
function isObject(value) {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}
function same(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}
const account = process.env.CLOUDFLARE_ACCOUNT_ID;
const apiToken = process.env.CLOUDFLARE_API_TOKEN;
const projectName = process.env.CLOUDFLARE_PAGES_PROJECT;
assert(account && apiToken && projectName, 'DEPLOY_CREDENTIALS_MISSING');

let authorization;
try {
  authorization = JSON.parse(
    await readFile('.airlab/deploy/nemotron-ultra-selftest-request.json', 'utf8'),
  );
} catch {
  stop('REQUEST_UNREADABLE');
}
assert(
  authorization?.schemaVersion === 1 &&
  authorization?.operation === 'authorize_ultra_free_self_test' &&
  authorization?.environment === 'web-private-production' &&
  authorization?.routeId === routeId &&
  authorization?.model === modelId &&
  authorization?.confirmation === 'OWNER_AUTHORIZED_NVIDIA_ULTRA_FREE_PROTOTYPE',
  'REQUEST_MISMATCH',
);
const apiUrl =
  'https://api.cloudflare.com/client/v4/accounts/' +
  encodeURIComponent(account) + '/pages/projects/' +
  encodeURIComponent(projectName);

async function cloudflare(method, payload) {
  let response;
  try {
    response = await fetch(apiUrl, {
      method,
      headers: {
        'Authorization': 'Bearer ' + apiToken,
        'Accept': 'application/json',
        ...(payload ? { 'Content-Type': 'application/json' } : {}),
      },
      ...(payload ? { body: JSON.stringify(payload) } : {}),
      signal: AbortSignal.timeout(25000),
    });
  } catch {
    stop('CLOUDFLARE_API_UNREACHABLE');
  }
  if (!response.ok) stop('CLOUDFLARE_API_HTTP_' + response.status);
  let body;
  try {
    body = await response.json();
  } catch {
    stop('CLOUDFLARE_API_NOT_JSON');
  }
  assert(body?.success === true && isObject(body?.result), 'CLOUDFLARE_API_REJECTED');
  return body.result;
}
function readProductionVars(project) {
  const env = project?.deployment_configs?.production?.env_vars;
  assert(isObject(env), 'PRODUCTION_BINDINGS_UNREADABLE');
  return env;
}
function readRouting(env) {
  const data = env[variableName];
  // Do NOT downgrade an encrypted secret or attempt to read a masked value.
  assert(data?.type === 'plain_text' && typeof data.value === 'string',
    'ROUTING_VARIABLE_NOT_PLAINTEXT');
  let parsed;
  try {
    parsed = JSON.parse(data.value);
  } catch {
    stop('ROUTES_JSON_INVALID');
  }
  assert(isObject(parsed) && Array.isArray(parsed.orchestration),
    'ORCHESTRATION_ROUTES_NOT_CONFIGURED');
  return parsed;
}
function checkSafeTarget(env, config) {
  const hits = config.orchestration.filter((r) => r?.id === routeId);
  assert(hits.length === 1, 'TARGET_ROUTE_MISSING_OR_DUPLICATED');
  const route = hits[0];
  assert(route.model === modelId, 'TARGET_MODEL_MISMATCH');
  let endpoint;
  try {
    endpoint = new URL(route.endpoint);
  } catch {
    stop('UPSTREAM_ENDPOINT_INVALID');
  }
  assert(endpoint.protocol === 'https:' &&
    endpoint.hostname === 'integrate.api.nvidia.com' &&
    endpoint.pathname === '/v1/chat/completions' &&
    !endpoint.search && !endpoint.hash &&
    !endpoint.username && !endpoint.password,
    'NOT_VERIFIED_NVIDIA_PROTOTYPE_ENDPOINT');
  const secretName = route.apiKeySecret;
  assert(typeof secretName === 'string' &&
    /^[A-Z][A-Z0-9_]{2,63}$/.test(secretName),
    'CREDENTIAL_REFERENCE_INVALID');
  assert(env[secretName]?.type === 'secret_text',
    'CREDENTIAL_BINDING_NOT_ENCRYPTED_OR_MISSING');
  return route;
}
function assertOtherBindings(before, after) {
  const beforeKeys = Object.keys(before).sort();
  const afterKeys = Object.keys(after).sort();
  assert(same(beforeKeys, afterKeys), 'OTHER_BINDINGS_NAMES_CHANGED');
  for (const key of beforeKeys) {
    if (key === variableName) continue;
    assert(before[key]?.type === after[key]?.type, 'OTHER_BINDINGS_TYPE_CHANGED');
    if (before[key]?.type === 'plain_text') {
      assert(before[key]?.value === after[key]?.value,
        'OTHER_PLAINTEXT_BINDING_CHANGED');
    }
    // Encrypted values are never retrieved, transformed or compared.
  }
}

const beforeProject = await cloudflare('GET');
assert(beforeProject.name === projectName, 'PROJECT_NAME_MISMATCH');
const beforeEnv = readProductionVars(beforeProject);
const beforeRoutes = readRouting(beforeEnv);
const target = checkSafeTarget(beforeEnv, beforeRoutes);
if (target.selfTestFree === true) {
  console.log(gate + '_ALREADY_AUTHORIZED');
  process.exit(0);
}
assert(target.selfTestFree === undefined || target.selfTestFree === false,
  'UNEXPECTED_TEST_FLAG');
assert(beforeRoutes.orchestration.length >= 2,
  'ROUTES_UNEXPECTEDLY_INCOMPLETE');
const afterRoutes = structuredClone(beforeRoutes);
const afterTarget = afterRoutes.orchestration.find((r) => r.id === routeId);
afterTarget.selfTestFree = true;
const afterValue = JSON.stringify(afterRoutes);
const beforeValue = beforeEnv[variableName].value;
assert(afterValue !== beforeValue, 'NO_CHANGE');

function changeRequest(value) {
  // Cloudflare PATCH merges the specified env_vars key; keys are deleted
  // only when explicitly set to null. Never send any other binding.
  return {
    deployment_configs: {
      production: {
        env_vars: {
          [variableName]: { type: 'plain_text', value },
        },
      },
    },
  };
}

// The only authorized write: change one existing non-secret routing variable.
console.log(gate + '_PREFLIGHT_PASS');
await cloudflare('PATCH', changeRequest(afterValue));

let verified = false;
try {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const afterProject = await cloudflare('GET');
    const afterEnv = readProductionVars(afterProject);
    assertOtherBindings(beforeEnv, afterEnv);
    const liveRoutes = readRouting(afterEnv);
    checkSafeTarget(afterEnv, liveRoutes);
    if (same(liveRoutes, afterRoutes)) {
      verified = true;
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 1200));
  }
} catch {
  // Rollback is attempted without displaying any value. The job fails even
  // if rollback succeeds, so the team is alerted to inspect the configuration.
  try {
    await cloudflare('PATCH', changeRequest(beforeValue));
    console.error(gate + '_ROLLBACK_ATTEMPTED');
  } catch {
    console.error(gate + '_ROLLBACK_FAILED_REQUIRES_MANUAL_CHECK');
  }
  stop('POST_WRITE_VERIFICATION_FAILED');
}
if (!verified) {
  try {
    await cloudflare('PATCH', changeRequest(beforeValue));
    console.error(gate + '_ROLLBACK_ATTEMPTED');
  } catch {
    console.error(gate + '_ROLLBACK_FAILED_REQUIRES_MANUAL_CHECK');
  }
  stop('PATCH_NOT_VISIBLE');
}
console.log(gate + '_CONFIG_PATCH_VERIFIED');
console.log('NEXT_GATE: new private Pages deployment then authenticated diagnostic Self-Test.');
