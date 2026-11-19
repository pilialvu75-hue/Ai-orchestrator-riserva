import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { createGitHubCounterRunnerClient } from '../../scripts/web/github_counter_runner_client.mjs';

const head = 'ab'.repeat(20);
const repo = { id: 1235011890 };
const run = {
  id: 17, event: 'workflow_dispatch', run_attempt: 1,
  head_branch: 'main', head_sha: head, path: '.github/workflows/web-counter-runner.yml',
  status: 'completed', conclusion: 'success', repository: repo, head_repository: repo,
};
const digest = 'ef'.repeat(32);
const artifact = {
  id: 71, name: 'aivexus-counter-envelope', expired: false, size_in_bytes: 4096,
  digest: 'sha256:' + digest,
  workflow_run: {
    id: run.id, repository_id: repo.id, head_repository_id: repo.id,
    head_branch: 'main', head_sha: head,
  },
};

function setup(responses) {
  const calls = [];
  const client = createGitHubCounterRunnerClient({
    token: 'local-fixture', expectedHeadSha: head,
    async fetchImpl(url, options) {
      assert.equal(new URL(url).origin, 'https://api.github.com');
      assert.equal(options.redirect, 'error');
      assert.equal(options.headers.Authorization, 'Bearer local-fixture');
      const next = responses[calls.length];
      calls.push({ url, options });
      return next instanceof Response ? next : Response.json(next);
    },
  });
  return { client, calls };
}

test('dispatch records the returned run id and verifies artifact provenance', async () => {
  const { client, calls } = setup([
    { workflow_run_id: run.id }, run, { total_count: 1, artifacts: [artifact] },
  ]);
  const ticket = crypto.randomUUID();
  assert.equal(await client.dispatch({ ticket, publicKeySpki: 'YWJj' }), run.id);
  assert.equal(calls[0].options.method, 'POST');
  assert.match(calls[0].url, /\/web-counter-runner\.yml\/dispatches$/);
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    ref: 'main', inputs: { ticket, public_key: 'YWJj' },
  });
  assert.deepEqual(await client.readResult(run.id), {
    status: 'ready', artifactId: artifact.id, sha256: digest, size: 4096,
  });
});

test('does not look up artifacts for untrusted or unfinished runs', async () => {
  for (const tampered of [
    { head_sha: '0'.repeat(40) }, { run_attempt: 2 }, { event: 'push' },
    { head_repository: { id: 33 } }, { path: '.github/workflows/another.yml' },
  ]) {
    const { client, calls } = setup([{ ...run, ...tampered }]);
    await assert.rejects(client.readResult(run.id), /provenance/);
    assert.equal(calls.length, 1);
  }
  const pending = setup([{ ...run, status: 'in_progress' }]);
  assert.deepEqual(await pending.client.readResult(run.id), { status: 'pending' });
  const failed = setup([{ ...run, conclusion: 'failure' }]);
  assert.deepEqual(await failed.client.readResult(run.id), { status: 'failed' });
});

test('rejects duplicates, expired and oversized archives and avoids dispatch retry', async () => {
  for (const list of [
    { total_count: 2, artifacts: [artifact, artifact] },
    { total_count: 1, artifacts: [{ ...artifact, expired: true }] },
    { total_count: 1, artifacts: [{ ...artifact, size_in_bytes: 128 * 1024 + 1 }] },
    { total_count: 1, artifacts: [{ ...artifact, workflow_run: { ...artifact.workflow_run, id: 25 } }] },
  ]) {
    const { client } = setup([run, list]);
    await assert.rejects(client.readResult(run.id), /artifact provenance/);
  }
  const { client, calls } = setup([new Response(null, { status: 503 })]);
  await assert.rejects(client.dispatch({ ticket: crypto.randomUUID(), publicKeySpki: 'YWJj' }));
  assert.equal(calls.length, 1);
});

const archive = Buffer.from(
  'UEsDBBQAAAAAAAAAIQCjuVTHDgAAAA4AAAAPAAAAY291bnRlci5haXZleHVzbG9jYWwtZW52ZWxvcGVQSwECFAAUAAAAAAAAACEAo7lUxw4AAAAOAAAADwAAAAAAAAAAAAAAgAEAAAAAY291bnRlci5haXZleHVzUEsFBgAAAAABAAEAPQAAADsAAAAAAA==',
  'base64',
);
const storage = 'https://artifacts.blob.core.windows.net/private-fixture';

function downloadFixture({ url = storage, body = archive, expected = archive } = {}) {
  let requests = 0;
  const client = createGitHubCounterRunnerClient({
    token: 'local-fixture', expectedHeadSha: head,
    async fetchImpl(target, options) {
      requests++;
      if (requests === 1) {
        assert.equal(new URL(target).origin, 'https://api.github.com');
        assert.equal(options.redirect, 'manual');
        assert.equal(options.headers.Authorization, 'Bearer local-fixture');
        return new Response(null, { status: 302, headers: { location: url } });
      }
      assert.equal(target, storage);
      assert.equal(options.redirect, 'error');
      assert.equal(options.credentials, 'omit');
      assert.equal(options.headers, undefined);
      return new Response(body);
    },
  });
  return {
    client,
    result: { status: 'ready', artifactId: 71, size: expected.length,
      sha256: createHash('sha256').update(expected).digest('hex') },
    get requests() { return requests; },
  };
}

test('downloads a bounded GitHub archive without forwarding the token', async () => {
  const { client, result } = downloadFixture();
  assert.equal(Buffer.from(await client.downloadArchive(result)).toString(), 'local-envelope');
  const untrusted = downloadFixture({ url: 'https://artifacts.blob.core.windows.net.example.org/invalid' });
  await assert.rejects(untrusted.client.downloadArchive(untrusted.result), /redirect/);
  assert.equal(untrusted.requests, 1);
  const oversized = downloadFixture({ body: Buffer.concat([archive, Buffer.from([1])]) });
  await assert.rejects(oversized.client.downloadArchive(oversized.result), /length/);
  const changed = Buffer.from(archive);
  changed[50] ^= 1;
  const corrupted = downloadFixture({ body: changed });
  await assert.rejects(corrupted.client.downloadArchive(corrupted.result), /digest/);
  const wrongName = Buffer.from(archive);
  wrongName[30] ^= 1;
  const wrong = downloadFixture({ body: wrongName, expected: wrongName });
  await assert.rejects(wrong.client.downloadArchive(wrong.result), /format/);
});
