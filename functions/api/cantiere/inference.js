const CAPABILITIES = new Set([
  'orchestration',
  'architecture_reasoning',
  'coding',
  'review',
]);
const MESSAGE_ROLES = new Set(['system', 'user', 'assistant']);
const MAX_MESSAGES = 32;
const MAX_MESSAGE_CHARS = 12000;
const MAX_TOTAL_CHARS = 60000;
const MAX_BODY_CHARS = 100000;
const MAX_OUTPUT_CHARS = 100000;
const MAX_ROUTE_ATTEMPTS = 2;
const MAX_RETRY_DELAY_MS = 2000;

function jsonResponse(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      'Cache-Control': 'no-store',
      'Content-Type': 'application/json; charset=utf-8',
      'X-Content-Type-Options': 'nosniff',
    },
  });
}

function error(code, status) {
  return jsonResponse(
    {
      version: 1,
      error: { code },
    },
    status,
  );
}

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

      valid.push({ id, endpoint: url.toString(), model, apiKeySecret });
    }
    if (valid.length > 0) result[capability] = valid;
  }

  return result;
}

function boundedNumber(value, min, max, fallback) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, value));
}

function validateMessages(value) {
  if (!Array.isArray(value) || value.length < 1 || value.length > MAX_MESSAGES) {
    return null;
  }

  const messages = [];
  let totalChars = 0;
  for (const row of value) {
    if (!row || typeof row !== 'object') return null;
    if (!MESSAGE_ROLES.has(row.role)) return null;
    if (typeof row.content !== 'string') return null;

    const content = row.content.trim();
    if (!content || content.length > MAX_MESSAGE_CHARS) return null;
    totalChars += content.length;
    if (totalChars > MAX_TOTAL_CHARS) return null;

    messages.push({ role: row.role, content });
  }

  if (messages[messages.length - 1].role !== 'user') return null;
  return messages;
}

function safeIdentity(value) {
  if (typeof value !== 'string') return undefined;
  const normalized = value.trim();
  if (!normalized || normalized.length > 160) return undefined;
  return normalized;
}

function isTransientStatus(status) {
  return status === 408 || status === 429 || (status >= 500 && status <= 504);
}

function retryDelayMs(response, attempt) {
  const raw = response.headers.get('retry-after');
  if (raw) {
    const seconds = Number(raw);
    if (Number.isFinite(seconds) && seconds >= 0) {
      return Math.min(MAX_RETRY_DELAY_MS, Math.round(seconds * 1000));
    }
  }
  return Math.min(MAX_RETRY_DELAY_MS, 250 * (attempt + 1));
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function callRoute(route, request) {
  const apiKey = request.env[route.apiKeySecret];
  if (!apiKey) return null;

  for (let attempt = 0; attempt < MAX_ROUTE_ATTEMPTS; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 80000);
    try {
      const response = await fetch(route.endpoint, {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model: route.model,
          messages: request.messages,
          max_tokens: request.maxTokens,
          temperature: request.temperature,
          top_p: request.topP,
          stream: false,
        }),
        signal: controller.signal,
      });

      if (!response.ok) {
        if (
          attempt + 1 < MAX_ROUTE_ATTEMPTS &&
          isTransientStatus(response.status)
        ) {
          const delay = retryDelayMs(response, attempt);
          clearTimeout(timer);
          await sleep(delay);
          continue;
        }
        return { ok: false, status: response.status };
      }

      let decoded;
      try {
        decoded = await response.json();
      } catch (_) {
        return { ok: false, status: 502 };
      }

      const text = decoded?.choices?.[0]?.message?.content;
      if (
        typeof text !== 'string' ||
        !text.trim() ||
        text.length > MAX_OUTPUT_CHARS
      ) {
        return { ok: false, status: 502 };
      }

      const completionTokens = decoded?.usage?.completion_tokens;
      return {
        ok: true,
        text: text.trim(),
        model: route.model,
        routeId: route.id,
        tokensGenerated:
          Number.isInteger(completionTokens) && completionTokens >= 0
            ? completionTokens
            : 0,
      };
    } catch (_) {
      return { ok: false, status: 503 };
    } finally {
      clearTimeout(timer);
    }
  }

  return { ok: false, status: 502 };
}

export async function onRequest(context) {
  if (context.request.method !== 'POST') {
    return new Response('Method not allowed.', {
      status: 405,
      headers: {
        Allow: 'POST',
        'Cache-Control': 'no-store',
      },
    });
  }

  const contentType = context.request.headers.get('content-type') || '';
  if (!contentType.toLowerCase().includes('application/json')) {
    return error('content_type_required', 415);
  }

  const declaredLength = Number(
    context.request.headers.get('content-length') || '0',
  );
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_CHARS) {
    return error('request_too_large', 413);
  }

  let rawBody;
  try {
    rawBody = await context.request.text();
  } catch (_) {
    return error('invalid_body', 400);
  }
  if (rawBody.length > MAX_BODY_CHARS) {
    return error('request_too_large', 413);
  }

  let body;
  try {
    body = JSON.parse(rawBody);
  } catch (_) {
    return error('invalid_json', 400);
  }

  if (!body || typeof body !== 'object' || body.version !== 1) {
    return error('unsupported_request', 400);
  }

  const capability =
    typeof body.capability === 'string' ? body.capability.trim() : '';
  if (!CAPABILITIES.has(capability)) {
    return error('unsupported_capability', 400);
  }

  const messages = validateMessages(body.messages);
  if (!messages) return error('invalid_messages', 400);

  const routes = parseRoutes(context.env)[capability] || [];
  if (routes.length === 0) {
    return error('capability_unavailable', 503);
  }

  const request = {
    env: context.env,
    messages,
    maxTokens: Math.round(boundedNumber(body.maxTokens, 1, 4096, 512)),
    temperature: boundedNumber(body.temperature, 0, 1.5, 0.45),
    topP: boundedNumber(body.topP, 0.05, 1, 0.9),
    identity: {
      requestId: safeIdentity(body.requestId),
      projectId: safeIdentity(body.projectId),
      taskId: safeIdentity(body.taskId),
      executionId: safeIdentity(body.executionId),
      attemptId: safeIdentity(body.attemptId),
      checkpointId: safeIdentity(body.checkpointId),
    },
  };

  for (const route of routes) {
    const result = await callRoute(route, request);
    if (result?.ok) {
      return jsonResponse({
        version: 1,
        text: result.text,
        model: result.model,
        routeId: result.routeId,
        tokensGenerated: result.tokensGenerated,
      });
    }
  }

  return error('upstream_unavailable', 502);
}
