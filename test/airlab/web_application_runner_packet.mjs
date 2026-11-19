import assert from 'node:assert/strict';
import test from 'node:test';

import { createGitHubWebApplicationRunnerClient } from '../../scripts/web/github_counter_runner_client.mjs';
import { runEncryptedWebApplicationJob } from '../../scripts/web/run_encrypted_web_application_job.mjs';
import {
  decodeRunnerBase64, decodeWebAppJob, decodeWebAppResult, encodeRunnerBase64,
  encodeWebAppJob, encodeWebAppResult, importWebAppAuthorizationKey, runnerPayloadSha256,
} from '../../scripts/web/web_application_runner_packet.mjs';

const generateRsa = () => crypto.subtle.generateKey({
  name: 'RSA-OAEP', modulusLength: 2048, hash: 'SHA-256', publicExponent: new Uint8Array([1, 0, 1]),
}, true, ['encrypt', 'decrypt']);
const newAuthorizationKey = () => importWebAppAuthorizationKey(encodeRunnerBase64(crypto.getRandomValues(new Uint8Array(32))));

async function fixture({ now } = {}) {
  const [runner, pages, authorizationKey] = await Promise.all([generateRsa(), generateRsa(), newAuthorizationKey()]);
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
    source, checks, input, encodeJob, runner, pages, ticket, authorizationKey, jobSha256,
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

test('the isolated worker reads an encrypted job and returns an encrypted verified ZIP', { skip: !executable, timeout: 20000 }, async () => {
  const f = await fixture();
  const repo = { id: 1235011890 };
  const head = 'ab'.repeat(20);
  const storage = 'https://artifacts.blob.core.windows.net/test-fixture';
  let archive;
  let posts = 0;
  const github = createGitHubWebApplicationRunnerClient({ token: 'local-placeholder', expectedHeadSha: head,
    async fetchImpl(url, opts) {
      if (url === storage) {
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
        const output = await runEncryptedWebApplicationJob({ ...f.job,
          input: inputs.job, ticket: inputs.ticket, executable });
        archive = gitHubArchive(output);
        return Response.json({ workflow_run_id: 19 });
      }
      if (path.endsWith('/runs/19')) return Response.json({
        id: 19, event: 'workflow_dispatch', run_attempt: 1, head_branch: 'main', head_sha: head,
        path: '.github/workflows/web-application-runner.yml', repository: repo, head_repository: repo,
        status: 'completed', conclusion: 'success',
      });
      if (path.endsWith('/runs/19/artifacts')) return Response.json({ total_count: 1, artifacts: [{
        id: 23, name: 'aivexus-application-envelope', expired: false, size_in_bytes: archive.length,
        digest: 'sha256:' + await runnerPayloadSha256(archive), workflow_run: {
          id: 19, repository_id: repo.id, head_repository_id: repo.id, head_branch: 'main', head_sha: head,
        },
      }] });
      assert.match(path, /\/artifacts\/23\/zip$/);
      return new Response(null, { status: 302, headers: { location: storage } });
    },
  });
  const runId = await github.dispatch({ ticket: f.ticket, input: f.input });
  assert.equal(posts, 1);
  const packet = await github.downloadArchive(await github.readResult(runId));
  const result = await decodeWebAppResult({ ...f.result, packet });
  assert.equal(result.status, 'verified', JSON.stringify(result.attempts));
  assert.equal(result.attempts[0].checks, 2);
  const zip = decodeRunnerBase64(result.artifact.zip, 100000);
  assert.equal(await runnerPayloadSha256(zip), result.artifact.sha256);
  assert.equal(await runnerPayloadSha256(new TextEncoder().encode(JSON.stringify(result.source))), result.artifact.sourceSha256);
  assert.ok(Buffer.from(zip).includes(Buffer.from(f.source.files[1].content)));
  assert.ok(!Buffer.from(packet).includes(Buffer.from(f.source.files[1].content)));
});
