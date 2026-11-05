import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

// Load the actual Pages Function as ESM without executing any network call.
// This suite uses only fake credentials and mocked HTTP responses.
const source = await readFile('functions/api/cantiere/inference.js', 'utf8');
const { onRequest } = await import(
  'data:text/javascript;base64,' + Buffer.from(source).toString('base64')
);

const marker = 'AIVEXUS_WEB_SELF_TEST_OK';
const endpoint = 'https://integrate.api.nvidia.com/v1/chat/completions';
const routes = [
  { id: 'nemotron-ultra-orchestrator', model: 'nvidia/nemotron-3-ultra-550b-a55b' },
  { id: 'kimi-k26-orchestrator', model: 'moonshotai/kimi-k2.6', manualOnly: true },
  { id: 'deepseek-v41-flash-orchestrator', model: 'deepseek-ai/deepseek-v4.1-flash', manualOnly: true },
].map((route) => ({
  ...route,
  apiKeySecret: 'NVIDIA_TEST_BINDING',
  endpoint,
  selfTestFree: true,
}));
const env = {
  CANTIERE_CLOUD_ROUTES_JSON: JSON.stringify({ orchestration: routes }),
  NVIDIA_TEST_BINDING: 'synthetic-placeholder-never-a-real-token',
};
async function request({ routeId, mockResponse, selfTest = true }) {
  let received;
  const previousFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    assert.equal(url.toString(), endpoint);
    received = JSON.parse(options.body);
    return mockResponse();
  };
  try {
    const body = {
      version: 1,
      capability: 'orchestration',
      selfTest,
      ...(routeId ? { routeId } : {}),
      ...(selfTest ? {} : { messages: [{ role: 'user', content: 'Synthetic project' }] }),
    };
    const req = new Request('https://aivexus.pages.dev/api/cantiere/inference', {
      method: 'POST',
      body: JSON.stringify(body),
      headers: { 'Content-Type': 'application/json' },
    });
    const res = await onRequest({ request: req, env });
    return { status: res.status, body: await res.json(), received };
  } finally {
    globalThis.fetch = previousFetch;
  }
}
function reply(text = marker) {
  return new Response(JSON.stringify({
    model: 'nvidia/nemotron-3-ultra-550b-a55b',
    choices: [{ message: { content: text }, finish_reason: 'stop' }],
    usage: { completion_tokens: 32 },
  }), { status: 200, headers: { 'Content-Type': 'application/json' } });
}

test('Nemotron preserves original 512-token, temperature 0 synthetic probe', async () => {
  const r = await request({
    routeId: 'nemotron-ultra-orchestrator', mockResponse: () => reply(),
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.text, marker);
  assert.equal(r.received.model, 'nvidia/nemotron-3-ultra-550b-a55b');
  assert.equal(r.received.max_tokens, 512);
  assert.equal(r.received.temperature, 0);
  assert.equal(r.received.top_p, 1);
});
for (const [routeId, model, topP] of [
  ['kimi-k26-orchestrator', 'moonshotai/kimi-k2.6', 1],
  ['deepseek-v41-flash-orchestrator', 'deepseek-ai/deepseek-v4.1-flash', 0.95],
]) {
  test('synthetic probe of ' + model + ' uses model-specific sampling', async () => {
    const r = await request({
      routeId, mockResponse: () => reply(),
    });
    assert.equal(r.status, 200);
    assert.equal(r.received.model, model);
    assert.equal(r.received.max_tokens, 1536);
    assert.equal(r.received.temperature, 1);
    assert.equal(r.received.top_p, topP);
    assert.equal(r.body.routeId, routeId);
  });

  test('ordinary project for ' + model + ' does not inherit synthetic parameters', async () => {
    const r = await request({
      routeId, selfTest: false, mockResponse: () => reply('PROPOSAL: synthetic'),
    });
    assert.equal(r.status, 200);
    assert.equal(r.received.model, model);
    assert.equal(r.received.max_tokens, 512);
    assert.equal(r.received.temperature, 0.45);
    assert.equal(r.received.top_p, 0.9);
  });
}
test('AUTO cannot choose manual-only Kimi or DeepSeek', async () => {
  const r = await request({ mockResponse: () => reply() });
  assert.equal(r.status, 200);
  assert.equal(r.received.model, 'nvidia/nemotron-3-ultra-550b-a55b');
});
test('422 upstream rejection is classified without echoing response body', async () => {
  const r = await request({
    routeId: 'kimi-k26-orchestrator',
    mockResponse: () => new Response(JSON.stringify({
      error: 'synthetic provider raw payload must never leave Pages',
    }), { status: 422 }),
  });
  assert.equal(r.status, 422);
  assert.equal(r.body.error.code, 'upstream_unavailable');
  assert.equal(r.body.error.upstreamStatus, 422);
  assert.equal(r.body.error.failureKind, 'upstream_http_rejection');
  assert.equal(r.body.error.routeId, 'kimi-k26-orchestrator');
  assert.doesNotMatch(JSON.stringify(r.body), /synthetic provider raw payload/);
});
test('empty final text is classified separately from NVIDIA HTTP failure', async () => {
  const r = await request({
    routeId: 'deepseek-v41-flash-orchestrator',
    mockResponse: () => new Response(JSON.stringify({
      model: 'deepseek-ai/deepseek-v4.1-flash',
      choices: [{ message: { content: null, reasoning_content: 'internal synthetic reasoning' } }],
    }), { status: 200 }),
  });
  assert.equal(r.status, 502);
  assert.equal(r.body.error.failureKind, 'no_final_text');
  assert.doesNotMatch(JSON.stringify(r.body), /internal synthetic reasoning/);
});
test('malformed JSON response is safely classified', async () => {
  const r = await request({
    routeId: 'kimi-k26-orchestrator',
    mockResponse: () => new Response('not JSON', { status: 200 }),
  });
  assert.equal(r.status, 502);
  assert.equal(r.body.error.failureKind, 'upstream_invalid_json');
});
