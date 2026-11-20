import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import test from 'node:test';
import { createChromiumWebVerifier } from '../../scripts/web/chromium_web_verifier.mjs';
import { packageVerifiedWebApplication } from '../../scripts/web/package_verified_web_application.mjs';
import { runWebApplicationVerification } from '../../scripts/web/run_web_application_verification.mjs';
import { verifyAndRepairWebApplication } from '../../scripts/web/verify_web_application.mjs';

const checks = [
  { action: 'text', selector: '#count', value: '0' },
  { action: 'click', selector: '#increment' },
  { action: 'text', selector: '#count', value: '1' },
];
const fixture = code => ({ title: 'Contatore', requirements: ['Il pulsante aumenta il totale di uno'], files: [
  { path: 'index.html', content: '<!doctype html><button id="increment">Aggiungi</button><output id="count">0</output><script src="count.js"></script>' },
  { path: 'count.js', content: code },
] });
const broken = fixture('let count =;');
const repaired = fixture(`let count = 0;
document.querySelector('#increment').addEventListener('click', () => {
  document.querySelector('#count').textContent = String(++count);
});`);

test('verification does not repair an infrastructure failure', async () => {
  const result = await verifyAndRepairWebApplication({
    source: broken, checks,
    verify: async () => ({ status: 'unavailable', diagnosis: 'browser_infrastructure' }),
    repair: async () => assert.fail('must not request a repair'),
  });
  assert.equal(result.status, 'unavailable');
  assert.equal(result.diagnosis, 'browser_infrastructure');
  assert.equal(result.attempts.length, 1);
});

test('verification allows at most three repairs of a reproducible code failure', async () => {
  let calls = 0;
  const result = await verifyAndRepairWebApplication({
    source: broken, checks,
    verify: async () => ({ status: 'code_error', diagnosis: 'javascript_error' }),
    repair: async () => ({ source: fixture(`let count =; // attempt ${++calls}`) }),
  });
  assert.equal(result.status, 'failed');
  assert.equal(result.diagnosis, 'javascript_error');
  assert.equal(calls, 3);
  assert.equal(result.attempts.length, 4);
});

test('verification rejects generated paths that escape the project before running a browser', async () => {
  const result = await verifyAndRepairWebApplication({
    source: { files: [...broken.files, { path: '../outside.js', content: '42' }] }, checks,
    verify: async () => assert.fail('unsafe project reached verifier'),
  });
  assert.equal(result.diagnosis, 'invalid_application_or_test_plan');
  assert.equal(result.attempts.length, 0);
});

const executable = process.env.AIVEXUS_WEB_CHROMIUM;
test('Chromium detects a syntax error and passes the same real DOM checks after repair', { skip: !executable, timeout: 50000 }, async t => {
  const endpoint = `https://api.cloudflare.com/client/v4/accounts/${'0'.repeat(32)}/ai/v1/chat/completions`;
  const model = '@cf/google/gemma-4-26b-a4b-it';
  const env = {
    AIVEXUS_WEB_BUILDER_FREE_ENABLED: 'true',
    AIVEXUS_WEB_BUILDER_ACCOUNT_ID: '0'.repeat(32),
    AIVEXUS_BUILDER_WORKERS_AI_TOKEN: 'local-placeholder',
  };
  const localFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = localFetch; });
  let calls = 0;
  globalThis.fetch = (url, options) => {
    if (String(url) !== endpoint) return localFetch(url, options);
    calls++;
    assert.equal(options.redirect, 'manual');
    assert.equal(options.headers.Authorization, 'Bearer local-placeholder');
    const request = JSON.parse(options.body);
    assert.equal(request.model, model);
    assert.equal(request.max_completion_tokens, 6144);
    assert.deepEqual(request.response_format, { type: 'json_object' });
    const input = JSON.parse(request.messages.at(-1).content);
    assert.equal(input.diagnosis, 'javascript_error');
    assert.deepEqual(input.source, broken);
    return Promise.resolve(Response.json({ model, choices: [
      { finish_reason: 'stop', message: { content: JSON.stringify({
        title: 'Ignored model title', requirements: ['Ignored requirement'], files: [repaired.files[1]],
      }) } },
    ] }));
  };
  const result = await runWebApplicationVerification({ source: broken, checks, executable, env });
  assert.equal(result.status, 'verified', JSON.stringify(result.attempts));
  assert.equal(calls, 1);
  assert.deepEqual(result.source, { ...repaired, files: [repaired.files[1], repaired.files[0]] });
  assert.deepEqual(result.attempts.map(attempt => attempt.status), ['code_error', 'passed']);
  assert.notEqual(result.attempts[0].sourceSha256, result.attempts[1].sourceSha256);
  assert.equal(result.attempts[1].repairProvenance.reportedModel, model);
  const { zip, sha256, sourceSha256 } = result.artifact;
  assert.equal(sourceSha256, result.attempts[1].sourceSha256);
  assert.match(sha256, /^[0-9a-f]{64}$/);
  assert.equal(zip.readUInt32LE(), 0x04034b50);
  assert.ok(zip.includes(Buffer.from(repaired.files[1].content)));
  assert.ok(!zip.includes(Buffer.from(broken.files[1].content)));
  await assert.rejects(packageVerifiedWebApplication({ ...result, source: broken }), /changed/);
});

test('Chromium keeps generated application requests away from services on the host', { skip: !executable, timeout: 50000 }, async t => {
  let requests = 0;
  const canary = createServer((request, response) => {
    requests++;
    response.end('should not be reached');
  });
  await new Promise((resolve, reject) => {
    canary.once('error', reject);
    canary.listen(0, '127.0.0.1', resolve);
  });
  t.after(() => new Promise(resolve => canary.close(resolve)));
  const { port } = canary.address();
  const source = fixture(`document.querySelector('#increment').addEventListener('click', () => {
    fetch('http://127.0.0.1:${port}/test').then(
      () => { document.querySelector('#count').textContent = 'unexpected'; },
      () => { document.querySelector('#count').textContent = 'blocked'; }
    );
  });`);
  const result = await verifyAndRepairWebApplication({
    source, checks: [checks[0], checks[1], { ...checks[2], value: 'blocked' }],
    verify: createChromiumWebVerifier({ executable }),
  });
  assert.equal(result.status, 'verified', JSON.stringify(result.attempts));
  assert.equal(requests, 0);
});
