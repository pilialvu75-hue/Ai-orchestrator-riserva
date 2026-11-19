import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

import { onRequest as generate } from '../../functions/api/cantiere/proposals/generate.js';
import { onRequest as verify } from '../../functions/api/cantiere/proposals/verify.js';
import { onRequest as download } from '../../functions/api/cantiere/proposals/download.js';
import { runEncryptedWebApplicationJob } from '../../scripts/web/run_encrypted_web_application_job.mjs';
import {
  decodeRunnerBase64, decodeWebAppJob, decodeWebAppResult, encodeRunnerBase64,
  encodeWebAppJob, encodeWebAppResult, importWebAppAuthorizationKey, runnerPayloadSha256,
} from '../../scripts/web/web_application_runner_packet.mjs';

const generateRsa = () => crypto.subtle.generateKey({
  name: 'RSA-OAEP', modulusLength: 2048, hash: 'SHA-256', publicExponent: new Uint8Array([1, 0, 1]),
}, true, ['encrypt', 'decrypt']);
const generateAuthorizationSecret = () => encodeRunnerBase64(crypto.getRandomValues(new Uint8Array(32)));
const newAuthorizationKey = () => importWebAppAuthorizationKey(generateAuthorizationSecret());

async function fixture({ now } = {}) {
  const authorizationSecret = generateAuthorizationSecret();
  const [runner, pages, authorizationKey] = await Promise.all([
    generateRsa(), generateRsa(), importWebAppAuthorizationKey(authorizationSecret),
  ]);
  const source = { title: 'Fixture privata', requirements: ['Attiva il promemoria'], files: [
    { path: 'index.html', content: '<!doctype html><button id="toggle">Attiva</button><output id="state">Spento</output><script src="app.js"></script>' },
    { path: 'app.js', content: 'document.querySelector("#toggle").onclick = () => { document.querySelector("#state").textContent = "Attivo"; };' },
  ] };
  const checks = [{ action: 'click', selector: '#toggle' }, { action: 'text', selector: '#state', value: 'Attivo' }];
  const resultPublicKeySpki = encodeRunnerBase64(new Uint8Array(await crypto.subtle.exportKey('spki', pages.publicKey)));
  const ticket = crypto.randomUUID();
  const encodeJob = { publicKey: runner.publicKey, authorizationKey, ticket, source, checks, resultPublicKeySpki, now };
  const { input, jobSha256 } = await encodeWebAppJob(encodeJob);
  return {
    source, checks, input, encodeJob, runner, pages, ticket, authorizationKey, authorizationSecret, jobSha256,
    job: { privateKey: runner.privateKey, authorizationKey, ticket, input },
    result: { privateKey: pages.privateKey, authorizationKey, ticket, jobSha256 },
  };
}

test('job recipient and result bytes are bound to an authorized request', async () => {
  const f = await fixture({ now: 1000 });
  const job = await decodeWebAppJob({ ...f.job, now: 1001 });
  assert.deepEqual(job.source, f.source);
  assert.deepEqual(job.checks, f.checks);
  assert.equal(job.jobSha256, f.jobSha256);
  assert.doesNotMatch(f.input, /Fixture privata|document/);
  await assert.rejects(decodeWebAppJob({ ...f.job, now: 1901 }), /expired/);
  await assert.rejects(decodeWebAppJob({ ...f.job, now: 970 - 1 }), /expired/);
  await assert.rejects(decodeWebAppJob({ ...f.job, now: 1001, ticket: crypto.randomUUID() }), /authorization/);
  await assert.rejects(decodeWebAppJob({ ...f.job, now: 1001, authorizationKey: await newAuthorizationKey() }), /authorization/);
  const corrupt = decodeRunnerBase64(f.input, 61000);
  corrupt[corrupt.length - 1] ^= 1;
  await assert.rejects(decodeWebAppJob({ ...f.job, now: 1001, input: encodeRunnerBase64(corrupt) }), /authorization/);
  const oversized = Array.from({ length: 8 }, () => encodeRunnerBase64(crypto.getRandomValues(new Uint8Array(8192)))).join('');
  await assert.rejects(encodeWebAppJob({ ...f.encodeJob, source: { huge: oversized } }), /payload limits/);
  const raw = Array.from({ length: 5 }, () => encodeRunnerBase64(crypto.getRandomValues(new Uint8Array(10240)))).join('');
  await assert.rejects(encodeWebAppJob({ ...f.encodeJob, source: { highEntropy: raw } }), /transport limits/);

  const result = { status: 'failed', diagnosis: 'javascript_error', attempts: [] };
  const packet = await encodeWebAppResult({ publicKey: job.resultPublicKey, authorizationKey: f.authorizationKey,
    ticket: f.ticket, jobSha256: job.jobSha256, result });
  assert.deepEqual(await decodeWebAppResult({ ...f.result, packet }), result);
  await assert.rejects(decodeWebAppResult({ ...f.result, packet, jobSha256: '0'.repeat(64) }), /digest mismatch/);
  await assert.rejects(decodeWebAppResult({ ...f.result, packet, privateKey: f.runner.privateKey }));
  await assert.rejects(decodeWebAppResult({ ...f.result, packet, ticket: crypto.randomUUID() }), /authorization/);
});

const executable = process.env.AIVEXUS_WEB_CHROMIUM;
function gitHubArchive(packet) {
  const name = Buffer.from('application.aivexus');
  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50);
  local.writeUInt32LE(packet.length, 18);
  local.writeUInt32LE(packet.length, 22);
  local.writeUInt16LE(name.length, 26);
  const central = Buffer.alloc(46);
  central.writeUInt32LE(0x02014b50);
  central.writeUInt32LE(packet.length, 20);
  central.writeUInt32LE(packet.length, 24);
  central.writeUInt16LE(name.length, 28);
  const tail = Buffer.alloc(22);
  tail.writeUInt32LE(0x06054b50);
  tail.writeUInt16LE(1, 8);
  tail.writeUInt16LE(1, 10);
  tail.writeUInt32LE(central.length + name.length, 12);
  tail.writeUInt32LE(local.length + name.length + packet.length, 16);
  return Buffer.concat([local, name, packet, central, name, tail]);
}

async function temporaryD1(t) {
  const { AIVEXUS_TEST_WRANGLER, AIVEXUS_TEST_D1_CONFIG, AIVEXUS_TEST_D1_STATE } = process.env;
  if (AIVEXUS_TEST_WRANGLER) {
    const { getPlatformProxy } = await import(pathToFileURL(AIVEXUS_TEST_WRANGLER));
    const open = () => getPlatformProxy({ configPath: AIVEXUS_TEST_D1_CONFIG,
      persist: { path: AIVEXUS_TEST_D1_STATE }, remoteBindings: false });
    let proxy = await open();
    t.after(() => proxy.dispose());
    return {
      get db() { return proxy.env.AIVEXUS_WEB_D1; },
      async reopen() { await proxy.dispose(); proxy = await open(); },
    };
  }
  const sqlite = new DatabaseSync(':memory:');
  t.after(() => sqlite.close());
  for (const migration of ['006_web_app_generations.sql', '007_web_app_verifications.sql']) {
    sqlite.exec(readFileSync(new URL('../../scripts/web/sql/' + migration, import.meta.url), 'utf8'));
  }
  return { db: { prepare(sql) {
    const statement = sqlite.prepare(sql);
    return { bind(...args) {
      const params = Object.fromEntries(args.map((value, index) => [
        '?' + (index + 1), value instanceof ArrayBuffer ? new Uint8Array(value) : value,
      ]));
      return { async first() { return statement.get(params) ?? null; } };
    } };
  } }, async reopen() {} };
}

test('Pages reserves one verification and serves its verified ZIP only to the owner', { skip: !executable, timeout: 30000 }, async t => {
  const f = await fixture();
  const platform = await temporaryD1(t);
  const accessKey = await crypto.subtle.generateKey({
    name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, hash: 'SHA-256', publicExponent: new Uint8Array([1, 0, 1]),
  }, true, ['sign', 'verify']);
  const issuer = 'https://aivexus-fixture.cloudflareaccess.com';
  const origin = 'https://aivexus.pages.dev';
  const audience = 'fixture';
  const kid = 'fixture-key';
  const jwk = { ...await crypto.subtle.exportKey('jwk', accessKey.publicKey), kid, alg: 'RS256', use: 'sig' };
  const signed = async sub => {
    const now = Math.floor(Date.now() / 1000);
    const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
    const unsigned = encode({ alg: 'RS256', kid }) + '.' + encode({ iss: issuer, aud: [audience], sub, iat: now - 5, exp: now + 300 });
    const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', accessKey.privateKey, Buffer.from(unsigned));
    return unsigned + '.' + Buffer.from(sig).toString('base64url');
  };
  const [owner, stranger] = await Promise.all([signed('owner'), signed('stranger')]);
  const repo = { id: 1235011890 };
  const head = 'ab'.repeat(20);
  const storage = 'https://artifacts.blob.core.windows.net/test-fixture';
  const model = '@cf/google/gemma-4-26b-a4b-it';
  const env = {
    AIVEXUS_WEB_ORIGIN: origin, AIVEXUS_WEB_ACCESS_ISSUER: issuer, AIVEXUS_WEB_ACCESS_AUDIENCE: audience,
    AIVEXUS_WEB_BUILDER_FREE_ENABLED: 'true',
    AIVEXUS_WEB_BUILDER_AI: { async run() { return { model, choices: [{ finish_reason: 'stop', message: {
      content: JSON.stringify({ ...f.source, checks: f.checks }),
    } }] }; } },
    AIVEXUS_COUNTER_GITHUB_TOKEN: 'fake', AIVEXUS_WEB_BUILDER_GITHUB_HEAD_SHA: head,
    AIVEXUS_WEB_BUILDER_JOB_AUTH_KEY: f.authorizationSecret,
    AIVEXUS_WEB_BUILDER_JOB_PUBLIC_KEY: encodeRunnerBase64(new Uint8Array(await crypto.subtle.exportKey('spki', f.runner.publicKey))),
    AIVEXUS_WEB_BUILDER_RESULT_PUBLIC_KEY: f.encodeJob.resultPublicKeySpki,
    AIVEXUS_WEB_BUILDER_RESULT_PRIVATE_KEY: encodeRunnerBase64(new Uint8Array(await crypto.subtle.exportKey('pkcs8', f.pages.privateKey))),
  };
  let archive;
  let posts = 0;
  let downloads = 0;
  let complete = false;
  let failDispatch = false;
  const localFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = localFetch; });
  globalThis.fetch = async (url, opts) => {
      if (String(url).startsWith('http://127.0.0.1:')) return localFetch(url, opts);
      const target = String(url);
      if (target === issuer + '/cdn-cgi/access/certs') return Response.json({ keys: [jwk] });
      if (url === storage) {
        downloads++;
        assert.equal(opts.headers, undefined);
        assert.equal(opts.credentials, 'omit');
        return new Response(archive);
      }
      const path = new URL(url).pathname;
      assert.equal(new URL(url).origin, 'https://api.github.com');
      if (path.endsWith('/web-application-runner.yml/dispatches')) {
        posts++;
        const { ref, inputs } = JSON.parse(opts.body);
        assert.equal(ref, 'main');
        assert.deepEqual(Object.keys(inputs).sort(), ['job', 'ticket']);
        if (failDispatch) return new Response(null, { status: 503 });
        const output = await runEncryptedWebApplicationJob({ ...f.job,
          input: inputs.job, ticket: inputs.ticket, executable });
        assert.ok(!Buffer.from(output).includes(Buffer.from(f.source.files[1].content)));
        archive = gitHubArchive(output);
        return Response.json({ workflow_run_id: 19 });
      }
      if (path.endsWith('/runs/19')) return Response.json({
        id: 19, event: 'workflow_dispatch', run_attempt: 1, head_branch: 'main', head_sha: head,
        path: '.github/workflows/web-application-runner.yml', repository: repo, head_repository: repo,
        status: complete ? 'completed' : 'in_progress', conclusion: complete ? 'success' : null,
      });
      if (path.endsWith('/runs/19/artifacts')) return Response.json({ total_count: 1, artifacts: [{
        id: 23, name: 'aivexus-application-envelope', expired: false, size_in_bytes: archive.length,
        digest: 'sha256:' + await runnerPayloadSha256(archive), workflow_run: {
          id: 19, repository_id: repo.id, head_repository_id: repo.id, head_branch: 'main', head_sha: head,
        },
      }] });
      assert.match(path, /\/artifacts\/23\/zip$/);
      return new Response(null, { status: 302, headers: { location: storage } });
  };
  function call(handler, route, token, body, query = '') {
    return handler({ request: new Request(`${origin}/api/cantiere/proposals/${route}${query}`, {
      method: body ? 'POST' : 'GET',
      headers: { 'Cf-Access-Jwt-Assertion': token, ...(body ? { Origin: origin, 'Content-Type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
    }), env: { ...env, AIVEXUS_WEB_D1: platform.db } });
  }
  const generationId = crypto.randomUUID();
  const query = `?generationId=${generationId}`;
  const generated = await (await call(generate, 'generate', owner, { generationId, prompt: 'Un promemoria' })).json();
  assert.equal(generated.status, 'generated');
  assert.equal((await call(verify, 'verify', stranger, { generationId })).status, 404);
  assert.equal((await (await call(verify, 'verify', owner, null, query)).json()).status, 'ready');
  const requests = await Promise.all(Array.from({ length: 5 }, () => call(verify, 'verify', owner, { generationId })));
  const states = await Promise.all(requests.map(response => response.json()));
  assert.ok(states.every(result => ['dispatching', 'submitted'].includes(result.status)), JSON.stringify(states));
  assert.equal(posts, 1);
  await platform.reopen();
  assert.equal((await (await call(verify, 'verify', owner, { generationId })).json()).status, 'submitted');
  assert.equal(downloads, 0);
  complete = true;
  await Promise.all(Array.from({ length: 5 }, () => call(verify, 'verify', owner, { generationId })));
  const result = await (await call(verify, 'verify', owner, null, query)).json();
  assert.equal(result.status, 'verified', JSON.stringify(result.attempts));
  assert.equal(result.attempts[0].checks, 2);
  assert.equal(posts, 1);
  assert.equal(downloads, 1);
  assert.equal(result.sourceSha256, generated.sourceSha256);
  assert.equal((await call(download, 'download', stranger, null, query)).status, 404);
  const artifact = await call(download, 'download', owner, null, query);
  assert.equal(artifact.status, 200);
  assert.equal(artifact.headers.get('content-type'), 'application/zip');
  const zip = new Uint8Array(await artifact.arrayBuffer());
  assert.equal(await runnerPayloadSha256(zip), result.zipSha256);
  assert.ok(Buffer.from(zip).includes(Buffer.from(f.source.files[1].content)));

  await platform.db.prepare(`UPDATE web_app_verifications SET zip_bytes = x'504b0304'
    WHERE owner_subject = 'owner' AND generation_id = ?1 RETURNING generation_id`).bind(generationId).first();
  assert.equal((await call(download, 'download', owner, null, query)).status, 503);

  failDispatch = true;
  const secondId = crypto.randomUUID();
  const second = await call(generate, 'generate', owner, { generationId: secondId, prompt: 'Un altro promemoria' });
  assert.equal((await second.json()).status, 'generated');
  const start = () => call(verify, 'verify', owner, { generationId: secondId });
  assert.equal((await (await start()).json()).status, 'review_required');
  assert.equal((await (await start()).json()).status, 'review_required');
  assert.equal(posts, 2);
});
