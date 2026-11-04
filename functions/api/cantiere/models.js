// Private, read-only diagnostic catalogue of the Web orchestration routes.
// Cloudflare Access must remain the authentication boundary. Never return
// endpoint URLs, secret names, token values, or authorization headers.
const MAX_MODELS = 20;

function providerLabel(endpoint) {
  const host = new URL(endpoint).hostname.toLowerCase();
  if (host === ['integrate', 'api', 'nvidia', 'com'].join('.')) {
    return 'NVIDIA NIM';
  }
  if (host === ['api', 'groq', 'com'].join('.')) return 'Groq';
  if (host === ['generativelanguage', 'googleapis', 'com'].join('.')) {
    return 'Gemini';
  }
  return 'Altro provider';
}

function catalogue(env) {
  const raw = env.CANTIERE_CLOUD_ROUTES_JSON;
  if (!raw) return { configStatus: 'missing', models: [] };
  let config;
  try {
    config = JSON.parse(raw);
  } catch (_) {
    return { configStatus: 'invalid', models: [] };
  }
  if (!config || typeof config !== 'object' || Array.isArray(config)) {
    return { configStatus: 'invalid', models: [] };
  }
  const rows = config.orchestration;
  if (!Array.isArray(rows)) {
    return { configStatus: 'no_orchestration_routes', models: [] };
  }
  const models = [];
  const seen = new Set();
  for (const row of rows) {
    if (models.length >= MAX_MODELS) break;
    if (!row || typeof row !== 'object') continue;
    const routeId = typeof row.id === 'string' ? row.id.trim() : '';
    const model = typeof row.model === 'string' ? row.model.trim() : '';
    const secret = typeof row.apiKeySecret === 'string'
      ? row.apiKeySecret.trim() : '';
    if (!/^[a-z0-9][a-z0-9_-]{0,63}$/i.test(routeId) || seen.has(routeId)) {
      continue;
    }
    if (!model || model.length > 200 ||
        !/^[A-Z][A-Z0-9_]{2,63}$/.test(secret)) continue;

    let url;
    try {
      url = new URL(row.endpoint);
    } catch (_) {
      continue;
    }
    if (url.protocol !== 'https:' || url.username || url.password) continue;
    seen.add(routeId);
    const bindingPresent = Boolean(env[secret]);
    const testApproved = row.selfTestFree === true;
    models.push({
      routeId,
      model,
      provider: providerLabel(url.toString()),
      bindingPresent,
      testApproved,
      selectable: bindingPresent && testApproved,
    });
  }
  return { configStatus: 'configured', models };
}

export function onRequest(context) {
  if (context.request.method !== 'GET') {
    return new Response('Method not allowed.', {
      status: 405,
      headers: { Allow: 'GET', 'Cache-Control': 'no-store' },
    });
  }
  const info = catalogue(context.env);
  return new Response(JSON.stringify({
    version: 1,
    capability: 'orchestration',
    ...info,
  }), {
    status: 200,
    headers: {
      'Cache-Control': 'no-store',
      'Content-Type': 'application/json; charset=utf-8',
      'X-Content-Type-Options': 'nosniff',
    },
  });
}
