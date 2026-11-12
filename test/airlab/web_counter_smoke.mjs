import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { runInNewContext } from 'node:vm';

const builder = 'scripts/web/build_counter_smoke.py';
const digest = (buffer) => createHash('sha256').update(buffer).digest('hex');

function execute(args) {
  return spawnSync('python3', [builder, ...args], { encoding: 'utf8' });
}
function withOutput(check) {
  const root = mkdtempSync(join(tmpdir(), 'aivexus-web-counter-'));
  try { return check(root); }
  finally { rmSync(root, { recursive: true, force: true }); }
}
function browser(script, values) {
  const elements = new Map(['count', 'increment', 'reset'].map(id =>
    [id, { textContent: '', handlers: {},
      addEventListener(event, fn) { this.handlers[event] = fn; } }]));
  const storage = {
    getItem(key) { return values.has(key) ? values.get(key) : null; },
    setItem(key, value) { values.set(key, value); },
  };
  runInNewContext(script, {
    document: { getElementById: id => elements.get(id) },
    localStorage: storage,
  });
  return {
    get: id => elements.get(id),
    click: id => elements.get(id).handlers.click(),
  };
}

test('counter smoke creates real files, validated ZIP and receipt with byte hashes', () => {
  withOutput(root => {
    const out = join(root, 'result');
    const built = execute(['--output', out]);
    assert.equal(built.status, 0, built.stderr);
    const receipt = JSON.parse(readFileSync(join(out, 'receipt.json'), 'utf8'));
    const zip = readFileSync(join(out, 'aivexus-web-counter-smoke.zip'));
    assert.equal(receipt.artifactSha256, digest(zip));
    assert.equal(receipt.buildState, 'files_packaged');
    assert.equal(receipt.validationState, 'separate_ci_gate_required');
    for (const [file, sha] of Object.entries(receipt.sourceSha256)) {
      assert.equal(digest(readFileSync(join(out, 'source', file))), sha);
    }
    const integrity = spawnSync('python3', [
      '-m', 'zipfile', '-t', join(out, 'aivexus-web-counter-smoke.zip'),
    ], { encoding: 'utf8' });
    assert.equal(integrity.status, 0, integrity.stderr);
    const syntax = spawnSync('node', ['--check', join(out, 'source', 'app.js')], {
      encoding: 'utf8',
    });
    assert.equal(syntax.status, 0, syntax.stderr);
    const html = readFileSync(join(out, 'source', 'index.html'), 'utf8');
    assert.match(html, /app\.js/);
    assert.match(html, /styles\.css/);
    assert.doesNotMatch(html, /https?:\/\/|fetch\(|<iframe/);
    assert.notEqual(execute(['--output', out]).status, 0);
    assert.equal(
      digest(readFileSync(join(out, 'aivexus-web-counter-smoke.zip'))),
      receipt.artifactSha256,
    );
  });
});

test('counter increments, persists across reload and resets without networking', () => {
  withOutput(root => {
    const out = join(root, 'built');
    assert.equal(execute(['--output', out]).status, 0);
    const script = readFileSync(join(out, 'source', 'app.js'), 'utf8');
    const values = new Map();
    let page = browser(script, values);
    assert.equal(page.get('count').textContent, '0');
    page.click('increment');
    page.click('increment');
    assert.equal(page.get('count').textContent, '2');
    page = browser(script, values);
    assert.equal(page.get('count').textContent, '2');
    page.click('reset');
    assert.equal(page.get('count').textContent, '0');
    assert.equal(browser(script, values).get('count').textContent, '0');
    values.set('aivexus-web-counter-smoke-v1', '-1');
    assert.equal(browser(script, values).get('count').textContent, '0');
  });
});

test('clean builds of the same source produce identical ZIP bytes', () => {
  withOutput(root => {
    const first = join(root, 'a');
    const second = join(root, 'b');
    assert.equal(execute(['--output', first]).status, 0);
    assert.equal(execute(['--output', second]).status, 0);
    assert.equal(digest(readFileSync(join(first, 'aivexus-web-counter-smoke.zip'))),
      digest(readFileSync(join(second, 'aivexus-web-counter-smoke.zip'))));
  });
});
