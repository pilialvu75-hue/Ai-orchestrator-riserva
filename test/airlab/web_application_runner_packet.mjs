import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

import { onRequest as generate } from '../../functions/api/cantiere/proposals/generate.js';
import { onRequest as verify } from '../../functions/api/cantiere/proposals/verify.js';
import { onRequest as download } from '../../functions/api/cantiere/proposals/download.js';
import { onRequest as readSource } from '../../functions/api/cantiere/proposals/source.js';
import { onRequest as preview } from '../../functions/api/cantiere/proposals/preview.js';
import { onRequest as revisions } from '../../functions/api/cantiere/proposals/revisions.js';
import { onRequest as selectRevision } from '../../functions/api/cantiere/proposals/select-revision.js';
import { onRequest as records } from '../../functions/api/cantiere/proposals/records.js';
import { onRequest as view } from '../../functions/api/cantiere/proposals/view.js';
import { onRequest as invite } from '../../functions/api/cantiere/proposals/invite.js';
import { onRequest as joinApp } from '../../functions/api/cantiere/proposals/join.js';
import { onRequest as integration } from '../../functions/api/cantiere/proposals/integration.js';
import { onRequest as releases } from '../../functions/api/cantiere/proposals/release.js';
import { onRequest as launch } from '../../functions/api/cantiere/proposals/launch.js';
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

test('membership migration retains existing records in the owner partition', () => {
  const db = new DatabaseSync(':memory:');
  try {
    const apply = name => db.exec(readFileSync(new URL('../../scripts/web/sql/' + name, import.meta.url), 'utf8'));
    apply('006_web_app_generations.sql');
    apply('009_web_app_revision_history.sql');
    apply('010_web_app_records.sql');
    db.prepare(`INSERT INTO web_app_generations(owner_subject,generation_id,prompt_sha256,status)
      VALUES ('owner','project',?,'generating')`).run('0'.repeat(64));
    db.exec(`INSERT INTO web_app_records(owner_subject,project_id,collection_name,record_id,record_version,data_json)
      VALUES ('owner','project','expenses','record',2,'{"cents":570}')`);
    apply('011_web_app_private_members.sql');
    const migrated = db.prepare('SELECT * FROM web_app_records').get();
    assert.equal(migrated.project_owner, 'owner');
    assert.equal(migrated.user_subject, 'owner');
    assert.equal(migrated.record_version, 2);
    assert.equal(migrated.data_json, '{"cents":570}');
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
  } finally { db.close(); }
});

async function fixture({ now } = {}) {
  const authorizationSecret = generateAuthorizationSecret();
  const [runner, pages, authorizationKey] = await Promise.all([
    generateRsa(), generateRsa(), importWebAppAuthorizationKey(authorizationSecret),
  ]);
  const source = { title: 'Spese private', requirements: ['Registra una spesa'], files: [
    { path: 'index.html', content: '<!doctype html><link rel="stylesheet" href="theme.css"><button id="toggle">Attiva</button><output id="state">Spento</output><script src="app.js"></script>' },
    { path: 'app.js', content: `document.querySelector("#toggle").onclick = async () => {
      await window.aivexusData.request({ action: 'create', collection: 'expenses', recordId: window.aivexusData.newRecordId(), data: { label: 'Treno', cents: 420 } });
      document.querySelector("#state").textContent = "Attivo";
    };` },
    { path: 'theme.css', content: 'output { color: rgb(0, 20, 30); }' },
  ], runtime: { kind: 'records', collections: [{ name: 'expenses', fields: { label: 'text', cents: 'integer' } }],
    integrations: ['github_repository'] } };
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
  assert.doesNotMatch(f.input, /Spese private|document/);
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
  for (const migration of ['006_web_app_generations.sql', '007_web_app_verifications.sql', '009_web_app_revision_history.sql', '010_web_app_records.sql', '011_web_app_private_members.sql', '012_web_app_private_releases.sql']) {
    sqlite.exec(readFileSync(new URL('../../scripts/web/sql/' + migration, import.meta.url), 'utf8'));
  }
  return { db: { prepare(sql) {
    const statement = sqlite.prepare(sql);
    return { bind(...args) {
      const params = Object.fromEntries(args.map((value, index) => [
        '?' + (index + 1), value instanceof ArrayBuffer ? new Uint8Array(value) : value,
      ]));
      return {
        async first() { return statement.get(params) ?? null; },
        async all() { return { success: true, results: statement.all(params) }; },
      };
    } };
  } }, async reopen() {} };
}

test('Pages verifies Web versions, restores history and serves ZIP only to the owner', { skip: !executable, timeout: 35000 }, async t => {
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
  const [owner, stranger, outsider] = await Promise.all([signed('owner'), signed('stranger'), signed('outsider')]);
  const repo = { id: 1235011890 };
  const head = 'ab'.repeat(20);
  const storage = 'https://artifacts.blob.core.windows.net/test-fixture/';
  const model = '@cf/google/gemma-4-26b-a4b-it';
  const env = {
    AIVEXUS_WEB_ORIGIN: origin, AIVEXUS_WEB_ACCESS_ISSUER: issuer, AIVEXUS_WEB_ACCESS_AUDIENCE: audience,
    AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT: 'owner',
    AIVEXUS_WEB_BUILDER_FREE_ENABLED: 'true',
    AIVEXUS_WEB_BUILDER_AI: { async run(selectedModel, request) {
      assert.equal(selectedModel, model);
      const input = request.messages.at(-1).content;
      let output = { ...f.source, checks: f.checks };
      if (input.startsWith('{')) {
        const revision = JSON.parse(input);
        assert.deepEqual(revision.checks, f.checks);
        modelRevisions++;
        output = {
          changedFiles: [{ path: 'theme.css', content: `output { color: rgb(${modelRevisions}, 20, 30); }` }],
          removedPaths: [], requirements: revision.source.requirements,
        };
      }
      return { model, choices: [{ finish_reason: 'stop', message: { content: JSON.stringify(output) } }] };
    } },
    AIVEXUS_COUNTER_GITHUB_TOKEN: 'fake', AIVEXUS_WEB_BUILDER_GITHUB_HEAD_SHA: head,
    AIVEXUS_WEB_BUILDER_JOB_AUTH_KEY: f.authorizationSecret,
    AIVEXUS_WEB_BUILDER_JOB_PUBLIC_KEY: encodeRunnerBase64(new Uint8Array(await crypto.subtle.exportKey('spki', f.runner.publicKey))),
    AIVEXUS_WEB_BUILDER_RESULT_PUBLIC_KEY: f.encodeJob.resultPublicKeySpki,
    AIVEXUS_WEB_BUILDER_RESULT_PRIVATE_KEY: encodeRunnerBase64(new Uint8Array(await crypto.subtle.exportKey('pkcs8', f.pages.privateKey))),
    AIVEXUS_WEB_APP_GITHUB_REPOSITORY: 'aivexus/public-fixture',
    AIVEXUS_WEB_APP_GITHUB_METADATA_TOKEN: 'fixture-server-only-token',
  };
  const archives = new Map();
  let posts = 0;
  let downloads = 0;
  let complete = false;
  let failDispatch = false;
  let modelRevisions = 0;
  let integrationRequests = 0;
  let fixturePrivate = false;
  let releasesEnabled = false;
  const localFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = localFetch; });
  globalThis.fetch = async (url, opts) => {
      if (String(url).startsWith('http://127.0.0.1:')) return localFetch(url, opts);
      const target = String(url);
      if (target === issuer + '/cdn-cgi/access/certs') return Response.json({ keys: [jwk] });
      if (target === 'https://api.github.com/repos/aivexus/public-fixture') {
        integrationRequests++;
        assert.equal(opts.method, 'GET');
        assert.equal(opts.redirect, 'manual');
        assert.equal(opts.headers.Authorization, 'Bearer fixture-server-only-token');
        return Response.json({ private: fixturePrivate, full_name: 'aivexus/public-fixture',
          stargazers_count: 19, secret: opts.headers.Authorization });
      }
      if (target.startsWith(storage)) {
        downloads++;
        assert.equal(opts.headers, undefined);
        assert.equal(opts.credentials, 'omit');
        return new Response(archives.get(Number(target.slice(storage.length))));
      }
      const path = new URL(url).pathname;
      assert.equal(new URL(url).origin, 'https://api.github.com');
      if (path.endsWith('/web-application-runner.yml/dispatches')) {
        posts++;
        const runId = 19 + posts;
        const { ref, inputs } = JSON.parse(opts.body);
        assert.equal(ref, 'main');
        assert.deepEqual(Object.keys(inputs).sort(), ['job', 'ticket']);
        if (failDispatch) return new Response(null, { status: 503 });
        const output = await runEncryptedWebApplicationJob({ ...f.job,
          input: inputs.job, ticket: inputs.ticket, executable });
        assert.ok(!Buffer.from(output).includes(Buffer.from(f.source.files[1].content)));
        archives.set(runId, gitHubArchive(output));
        return Response.json({ workflow_run_id: runId });
      }
      const runId = Number(path.match(/\/runs\/(\d+)/)?.[1]);
      if (path.endsWith(`/runs/${runId}`)) return Response.json({
        id: runId, event: 'workflow_dispatch', run_attempt: 1, head_branch: 'main', head_sha: head,
        path: '.github/workflows/web-application-runner.yml', repository: repo, head_repository: repo,
        status: complete ? 'completed' : 'in_progress', conclusion: complete ? 'success' : null,
      });
      if (path.endsWith(`/runs/${runId}/artifacts`)) return Response.json({ total_count: 1, artifacts: [{
        id: runId, name: 'aivexus-application-envelope', expired: false, size_in_bytes: archives.get(runId).length,
        digest: 'sha256:' + await runnerPayloadSha256(archives.get(runId)), workflow_run: {
          id: runId, repository_id: repo.id, head_repository_id: repo.id, head_branch: 'main', head_sha: head,
        },
      }] });
      const artifactId = Number(path.match(/\/artifacts\/(\d+)\/zip$/)?.[1]);
      assert.ok(archives.has(artifactId));
      return new Response(null, { status: 302, headers: { location: storage + artifactId } });
  };
  function call(handler, route, token, body, query = '') {
    return handler({ request: new Request(`${origin}/api/cantiere/proposals/${route}${query}`, {
      method: body ? 'POST' : 'GET',
      headers: { 'Cf-Access-Jwt-Assertion': token, ...(body ? { Origin: origin, 'Content-Type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
    }), env: { ...env, AIVEXUS_WEB_D1: platform.db, AIVEXUS_WEB_PRIVATE_RELEASES_ENABLED: String(releasesEnabled) } });
  }
  const generationId = crypto.randomUUID();
  const query = `?generationId=${generationId}`;
  const generated = await (await call(generate, 'generate', owner, { generationId, prompt: 'Un promemoria' })).json();
  assert.equal(generated.status, 'generated');
  assert.equal((await call(verify, 'verify', stranger, { generationId })).status, 403);
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
  assert.equal((await call(download, 'download', stranger, null, query)).status, 403);
  const artifact = await call(download, 'download', owner, null, query);
  assert.equal(artifact.status, 200);
  assert.equal(artifact.headers.get('content-type'), 'application/zip');
  const zip = new Uint8Array(await artifact.arrayBuffer());
  assert.equal(await runnerPayloadSha256(zip), result.zipSha256);
  assert.ok(Buffer.from(zip).includes(Buffer.from(f.source.files[1].content)));
  assert.ok(Buffer.from(zip).includes(Buffer.from('aivexus-runtime.json')));
  assert.equal((await call(readSource, 'source', stranger, null, query)).status, 403);
  assert.equal((await call(preview, 'preview', stranger, null, query)).status, 403);
  const sourceResponse = await call(readSource, 'source', owner, null, query);
  assert.equal(sourceResponse.status, 200);
  assert.equal(sourceResponse.headers.get('cache-control'), 'no-store');
  const source = await sourceResponse.json();
  assert.equal(source.sourceSha256, generated.sourceSha256);
  assert.equal(source.source.files[0].content, f.source.files[1].content);
  const viewResponse = await call(view, 'view', owner, null, query);
  assert.equal(viewResponse.status, 200);
  assert.match(viewResponse.headers.get('content-security-policy'), /frame-src 'self'/);
  assert.equal((await call(view, 'view', stranger, null, query)).status, 403);
  const recordId = crypto.randomUUID();
  const recordCall = (token, generationId, payload) => call(records, 'records', token, {
    generationId, collection: 'expenses', ...payload,
  });
  const createRecord = { action: 'create', recordId, data: { label: 'Treno', cents: 420 } };
  assert.equal((await recordCall(stranger, generationId, createRecord)).status, 403);
  const stored = await (await recordCall(owner, generationId, createRecord)).json();
  assert.equal(stored.record.version, 1);
  assert.equal((await recordCall(owner, generationId, createRecord)).status, 409);
  await platform.reopen();
  const opened = await (await recordCall(owner, generationId, { action: 'list' })).json();
  assert.deepEqual(opened.records, [{ recordId, version: 1, data: { label: 'Treno', cents: 420 } }]);
  const change = { action: 'update', recordId, version: 1, data: { label: 'Treno e metro', cents: 570 } };
  const update = await (await recordCall(owner, generationId, change)).json();
  assert.equal(update.record.version, 2);
  assert.equal((await recordCall(owner, generationId, change)).status, 409);
  assert.equal((await recordCall(owner, generationId, { ...change, data: { label: 'Treno', cents: '570' } })).status, 400);
  assert.equal((await call(invite, 'invite', owner, { generationId })).status, 404);
  env.AIVEXUS_WEB_APP_MEMBERS_ENABLED = 'true';
  assert.equal((await call(invite, 'invite', stranger, { generationId })).status, 403);
  const createdInvite = await (await call(invite, 'invite', owner, { generationId })).json();
  assert.equal(typeof createdInvite.token, 'string');
  assert.equal(await platform.db.prepare('SELECT token_sha256 FROM web_app_invites WHERE token_sha256 = ?1').bind(createdInvite.token).first(), null);
  assert.equal((await call(joinApp, 'join', owner, { token: createdInvite.token })).status, 404);
  const accepted = await (await call(joinApp, 'join', stranger, { token: createdInvite.token })).json();
  assert.equal(accepted.generationId, generationId);
  assert.equal((await call(joinApp, 'join', outsider, { token: createdInvite.token })).status, 404);
  assert.equal((await call(view, 'view', stranger, null, query)).status, 200);
  assert.equal((await call(readSource, 'source', stranger, null, query)).status, 403);
  assert.equal((await call(download, 'download', stranger, null, query)).status, 403);
  assert.deepEqual((await (await recordCall(stranger, generationId, { action: 'list' })).json()).records, []);
  const memberId = crypto.randomUUID();
  assert.equal((await recordCall(stranger, generationId, { ...createRecord, recordId: memberId })).status, 200);
  assert.equal((await recordCall(stranger, generationId, { ...change, version: 2 })).status, 409);
  assert.equal((await recordCall(owner, generationId, { ...change, recordId: memberId })).status, 409);
  await platform.reopen();
  const memberRows = await (await recordCall(stranger, generationId, { action: 'list' })).json();
  assert.deepEqual(memberRows.records, [{ recordId: memberId, version: 1, data: { label: 'Treno', cents: 420 } }]);
  const connector = { generationId, integration: 'github_repository' };
  assert.equal((await call(integration, 'integration', outsider, connector)).status, 404);
  assert.equal((await call(integration, 'integration', stranger, { ...connector, repository: 'other/forbidden' })).status, 400);
  assert.equal(integrationRequests, 0);
  const publicData = await (await call(integration, 'integration', stranger, connector)).json();
  assert.deepEqual(publicData, { version: 1, ok: true, repository: { fullName: 'aivexus/public-fixture', stars: 19 } });
  fixturePrivate = true;
  assert.equal((await call(integration, 'integration', owner, connector)).status, 503);
  assert.equal(integrationRequests, 2);
  const releaseId = crypto.randomUUID();
  const initialRelease = { action: 'publish', releaseId, generationId, expectedRevision: 0 };
  const releaseQuery = `?releaseId=${releaseId}`;
  assert.equal((await call(releases, 'release', owner, initialRelease)).status, 503);
  releasesEnabled = true;
  assert.equal((await call(releases, 'release', stranger, initialRelease)).status, 403);
  const released = await Promise.all(Array.from({ length: 4 }, async () =>
    (await call(releases, 'release', owner, initialRelease)).json()));
  assert.ok(released.every(event => event.revision === 1), JSON.stringify(released));
  assert.equal((await call(launch, 'launch', outsider, null, releaseQuery)).status, 404);
  const initialPage = await call(launch, 'launch', stranger, null, releaseQuery);
  assert.equal(initialPage.status, 200);
  assert.ok((await initialPage.text()).includes(generationId));

  const generationIds = [generationId];
  for (const instruction of ['Aggiungi un tema', 'Cambia colore', 'Aumenta il contrasto']) {
    const id = crypto.randomUUID();
    const payload = { generationId: id, baseGenerationId: generationIds.at(-1), instruction };
    assert.equal((await call(revisions, 'revisions', stranger, payload)).status, 403);
    const edits = await Promise.all(Array.from({ length: 3 }, () => call(revisions, 'revisions', owner, payload)));
    const outcomes = await Promise.all(edits.map(response => response.json()));
    assert.ok(outcomes.every(value => ['generating', 'generated'].includes(value.status)));
    assert.equal((await call(revisions, 'revisions', owner, { ...payload, instruction: 'Richiesta diversa' })).status, 409);
    assert.equal((await (await call(verify, 'verify', owner, { generationId: id })).json()).status, 'submitted');
    assert.equal((await (await call(verify, 'verify', owner, { generationId: id })).json()).status, 'verified');
    generationIds.push(id);
  }
  assert.equal(modelRevisions, 3);
  assert.equal(posts, 4);
  await platform.reopen();
  const finalQuery = `?generationId=${generationIds.at(-1)}`;
  assert.equal((await call(revisions, 'revisions', stranger, null, finalQuery)).status, 403);
  const history = await (await call(revisions, 'revisions', owner, null, finalQuery)).json();
  assert.equal(history.activeGenerationId, generationIds.at(-1));
  const revisedRecords = await (await recordCall(owner, generationIds.at(-1), { action: 'list' })).json();
  assert.deepEqual(revisedRecords.records, [{ recordId, version: 2, data: { label: 'Treno e metro', cents: 570 } }]);
  assert.deepEqual(history.revisions.map(version => version.generationId), generationIds.slice().reverse());
  assert.deepEqual(history.revisions.map(version => version.revision), [4, 3, 2, 1]);
  const updateRelease = { ...initialRelease, generationId: generationIds.at(-1), expectedRevision: 1 };
  assert.equal((await (await call(releases, 'release', owner, updateRelease)).json()).revision, 2);
  const updatedPage = await call(launch, 'launch', stranger, null, releaseQuery);
  assert.ok((await updatedPage.text()).includes(updateRelease.generationId));
  assert.equal((await call(releases, 'release', owner, { ...updateRelease, generationId: generationIds[1] })).status, 409);
  const rollback = { ...initialRelease, action: 'rollback', expectedRevision: 2 };
  assert.equal((await (await call(releases, 'release', owner, rollback)).json()).revision, 3);
  await platform.reopen();
  const releaseHistory = await (await call(releases, 'release', owner, null, finalQuery)).json();
  assert.deepEqual(releaseHistory.history.map(event => event.action), ['rollback', 'publish', 'publish']);
  const rolledBackPage = await call(launch, 'launch', stranger, null, releaseQuery);
  assert.ok((await rolledBackPage.text()).includes(generationId));
  assert.equal((await call(selectRevision, 'select-revision', stranger, { generationId })).status, 403);
  assert.equal((await (await call(selectRevision, 'select-revision', owner, { generationId })).json()).activeGenerationId, generationId);
  await platform.reopen();
  const restored = await (await call(revisions, 'revisions', owner, null, finalQuery)).json();
  assert.equal(restored.activeGenerationId, generationId);
  for (const [index, id] of generationIds.entries()) {
    const version = await (await call(readSource, 'source', owner, null, `?generationId=${id}`)).json();
    assert.equal(version.source.files[0].content, f.source.files[1].content);
    assert.equal(version.source.files[1].content, f.source.files[0].content);
    assert.ok(version.source.files.find(file => file.path === 'theme.css').content.includes(`rgb(${index},`));
  }

  await platform.db.prepare(`UPDATE web_app_verifications SET source_json = '{}'
    WHERE owner_subject = 'owner' AND generation_id = ?1 RETURNING generation_id`).bind(generationId).first();
  assert.equal((await call(readSource, 'source', owner, null, query)).status, 503);
  assert.equal((await call(preview, 'preview', owner, null, query)).status, 503);

  await platform.db.prepare(`UPDATE web_app_verifications SET zip_bytes = x'504b0304'
    WHERE owner_subject = 'owner' AND generation_id = ?1 RETURNING generation_id`).bind(generationId).first();
  assert.equal((await call(download, 'download', owner, null, query)).status, 503);

  const otherProjectId = crypto.randomUUID();
  const otherProject = await call(generate, 'generate', owner, { generationId: otherProjectId, prompt: 'Altre spese' });
  assert.equal((await otherProject.json()).status, 'generated');
  const verifyOther = () => call(verify, 'verify', owner, { generationId: otherProjectId });
  assert.equal((await (await verifyOther()).json()).status, 'submitted');
  assert.equal((await (await verifyOther()).json()).status, 'verified');
  assert.deepEqual((await (await recordCall(owner, otherProjectId, { action: 'list' })).json()).records, []);
  assert.equal((await recordCall(owner, otherProjectId, change)).status, 409);

  failDispatch = true;
  const secondId = crypto.randomUUID();
  const second = await call(generate, 'generate', owner, { generationId: secondId, prompt: 'Un altro promemoria' });
  assert.equal((await second.json()).status, 'generated');
  const start = () => call(verify, 'verify', owner, { generationId: secondId });
  assert.equal((await (await start()).json()).status, 'review_required');
  assert.equal((await (await start()).json()).status, 'review_required');
  assert.equal(posts, 6);
});
