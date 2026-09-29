const CAPABILITIES = new Set([
  'orchestration',
  'architecture_reasoning',
  'coding',
  'review',
]);

function parseRoutes(env) {
  const raw = env.CANTIERE_CLOUD_ROUTES_JSON;
  if (!raw) return {};

  let decoded;
  try {
    decoded = JSON.parse(raw);
  } catch (_) {
    return {};
  }

  if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) {
    return {};
  }

  const result = {};
  for (const capability of CAPABILITIES) {
    const rows = decoded[capability];
    if (!Array.isArray(rows)) continue;

    const valid = [];
    for (const row of rows) {
      if (!row || typeof row !== 'object') continue;
      const id = typeof row.id === 'string' ? row.id.trim() : '';
      const endpoint =
        typeof row.endpoint === 'string' ? row.endpoint.trim() : '';
      const model = typeof row.model === 'string' ? row.model.trim() : '';
      const apiKeySecret =
        typeof row.apiKeySecret === 'string' ? row.apiKeySecret.trim() : '';

      if (!/^[a-z0-9][a-z0-9_-]{0,63}$/i.test(id)) continue;
      if (!/^[A-Z][A-Z0-9_]{2,63}$/.test(apiKeySecret)) continue;
      if (!model || model.length > 200) continue;

      let url;
      try {
        url = new URL(endpoint);
      } catch (_) {
        continue;
      }
      if (url.protocol !== 'https:' || url.username || url.password) continue;
      if (!env[apiKeySecret]) continue;

      valid.push(id);
    }

    if (valid.length > 0) result[capability] = valid;
  }

  return result;
}

export async function onRequest(context) {
  if (context.request.method !== 'GET') {
    return new Response('Method not allowed.', {
      status: 405,
      headers: {
        Allow: 'GET',
        'Cache-Control': 'no-store',
      },
    });
  }

  const routes = parseRoutes(context.env);
  return new Response(
    JSON.stringify({
      version: 1,
      mode: 'auto',
      capabilities: Object.keys(routes),
    }),
    {
      status: 200,
      headers: {
        'Cache-Control': 'no-store',
        'Content-Type': 'application/json; charset=utf-8',
        'X-Content-Type-Options': 'nosniff',
      },
    },
  );
}
