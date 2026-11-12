import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const script = 'scripts/web/stamp_deployment_provenance.sh';
const sha = 'a'.repeat(40);
const outputName = '__aivexus_web_deployment.json';

function withBuild(callback) {
  const root = mkdtempSync(join(tmpdir(), 'aivexus-web-provenance-'));
  const build = join(root, 'web build with spaces');
  mkdirSync(build);
  try { return callback(build); }
  finally { rmSync(root, { recursive: true, force: true }); }
}
function stamp(build, value = sha, run = '42055659706') {
  return spawnSync('bash', [script, build, value, run], {
    encoding: 'utf8',
    env: { ...process.env, DUMMY_PROVIDER_KEY: 'never-export-this-test-secret' },
  });
}

test('source identity is deterministic, public-only and safe for paths with spaces', () => {
  withBuild((build) => {
    writeFileSync(join(build, 'index.html'), 'web');
    writeFileSync(join(build, 'main.dart.js'), 'bundle');
    const first = stamp(build);
    assert.equal(first.status, 0, first.stderr);
    const path = join(build, outputName);
    const content = readFileSync(path, 'utf8');
    assert.deepEqual(JSON.parse(content), {
      schemaVersion: 1, product: 'aivexus-web', gitSha: sha,
      githubRunId: '42055659706',
    });
    assert.doesNotMatch(content, /never-export-this-test-secret|DUMMY_PROVIDER_KEY|CLOUDFLARE/);
    const second = stamp(build);
    assert.equal(second.status, 0, second.stderr);
    assert.equal(readFileSync(path, 'utf8'), content);
  });
});

test('missing build artifacts and malformed identities fail closed', () => {
  withBuild((build) => {
    assert.notEqual(stamp(build).status, 0);
    writeFileSync(join(build, 'index.html'), 'web');
    writeFileSync(join(build, 'main.dart.js'), 'bundle');
    for (const [badSha, badRun] of [
      ['bad', '42055659706'], [sha, '0'], [sha, '12\\n99'], [sha, '1;echo']
    ]) {
      assert.notEqual(stamp(build, badSha, badRun).status, 0);
      assert.equal(existsSync(join(build, outputName)), false);
    }
  });
});
